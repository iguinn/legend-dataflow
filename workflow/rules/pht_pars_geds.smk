"""
Snakemake rules for processing pht (partition hit) tier data. This is done in 4 steps:
- extraction of calibration curves(s) for each run for each channel from cal data
- extraction of psd calibration parameters and partition level energy fitting for each channel over whole partition from cal data
- combining of all channels into single pars files with associated plot and results files
- running build hit over all channels using par file
"""

from legenddataflow.pars_loading import ParsCatalog
from legenddataflow.create_pars_keylist import ParsKeyResolve
from pathlib import Path
from legenddataflow.utils import filelist_path, set_last_rule_name
from legenddataflow.patterns import (
    get_pattern_pars_tmp_channel,
    get_pattern_plts_tmp_channel,
    get_pattern_log_channel,
    get_pattern_plts,
    get_pattern_tier,
    get_pattern_pars_tmp,
    get_pattern_log,
    get_pattern_pars,
)
from legenddataflow.execenv import execenv_pyexe

pht_par_catalog = ParsKeyResolve.get_par_catalog(
    ["-*-*-*-cal"],
    get_pattern_tier(config, "raw", check_in_cycle=False),
    {"cal": ["par_pht"], "lar": ["par_pht"]},
)

intier = "psp"

qc_pht_rules = {}
for key, dataset in part.datasets.items():
    for partition in dataset.keys():

        rule:
            input:
                cal_files=part.get_filelists(partition, key, intier),
                fft_files=part.get_filelists(partition, key, intier, datatype="fft"),
                pulser_files=[
                    str(file).replace("par_pht", "par_tcm")
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="pulser_ids",
                    )
                ],
                overwrite_files=get_overwrite_file(
                    "pht",
                    timestamp=part.get_timestamp(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                    ),
                ),
            wildcard_constraints:
                channel=part.get_wildcard_constraints(partition, key),
            params:
                datatype="cal",
                channel="{channel}" if key == "default" else key,
                timestamp=part.get_timestamp(
                    pht_par_catalog, partition, key, tier="pht"
                ),
                dsp_table_name=lambda wildcards: get_table_name(
                    metadata,
                    config,
                    "cal",
                    part.get_timestamp(pht_par_catalog, partition, key, tier="pht"),
                    wildcards.channel,
                    "dsp",
                ),
            output:
                hit_pars=[
                    temp(file)
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="qc",
                    )
                ],
                plot_file=[
                    temp(file)
                    for file in part.get_plt_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="qc",
                    )
                ],
            log:
                part.get_log_file(
                    pht_par_catalog,
                    partition,
                    key,
                    "pht",
                    time,
                    name="par_pht_qc",
                ),
            group:
                "par-pht"
            resources:
                mem_swap=len(part.get_filelists(partition, key, intier)) * 30,
                runtime=300,
            shell:
                execenv_pyexe(config, "par-geds-pht-qc") + "--log {log} "
                "--configs {configs} "
                "--metadata {meta} "
                "--datatype {params.datatype} "
                "--timestamp {params.timestamp} "
                "--channel {params.channel} "
                "--table-name {params.dsp_table_name} "
                "--save-path {output.hit_pars} "
                "--plot-path {output.plot_file} "
                "--overwrite-files {input.overwrite_files} "
                "--pulser-files {input.pulser_files} "
                "--fft-files {input.fft_files} "
                "--cal-files {input.cal_files}"

        set_last_rule_name(workflow, f"{key}-{partition}-build_pht_qc")

        if key in qc_pht_rules:
            qc_pht_rules[key].append(list(workflow.rules)[-1])
        else:
            qc_pht_rules[key] = [list(workflow.rules)[-1]]


# Merged energy and a/e supercalibrations to reduce number of rules as they have same inputs/outputs
# This rule builds the a/e calibration using the calibration dsp files for the whole partition
rule build_pht_qc:
    input:
        cal_files=os.path.join(
            filelist_path(config),
            "all-{experiment}-{period}-{run}-cal-" + f"{intier}.filelist",
        ),
        fft_files=os.path.join(
            filelist_path(config),
            "all-{experiment}-{period}-{run}-fft-" + f"{intier}.filelist",
        ),
        pulser_files=get_pattern_pars_tmp_channel(config, "tcm", "pulser_ids"),
        overwrite_files=lambda wildcards: get_overwrite_file("pht", wildcards=wildcards),
    params:
        datatype="cal",
        channel="{channel}",
        timestamp="{timestamp}",
        dsp_table_name=lambda wildcards: get_table_name(
            metadata, config, "cal", wildcards.timestamp, wildcards.channel, "dsp"
        ),
    output:
        hit_pars=temp(get_pattern_pars_tmp_channel(config, "pht", "qc")),
        plot_file=temp(get_pattern_plts_tmp_channel(config, "pht", "qc")),
    log:
        get_pattern_log_channel(config, "par_pht_qc", time),
    group:
        "par-pht"
    resources:
        mem_swap=60,
        runtime=300,
    shell:
        execenv_pyexe(config, "par-geds-pht-qc") + "--log {log} "
        "--configs {configs} "
        "--metadata {meta} "
        "--datatype {params.datatype} "
        "--timestamp {params.timestamp} "
        "--channel {params.channel} "
        "--table-name {params.dsp_table_name} "
        "--save-path {output.hit_pars} "
        "--plot-path {output.plot_file} "
        "--overwrite-files {input.overwrite_files} "
        "--pulser-files {input.pulser_files} "
        "--fft-files {input.fft_files} "
        "--cal-files {input.cal_files}"


fallback_qc_rule = list(workflow.rules)[-1]

rule_order_list = []
ordered = OrderedDict(qc_pht_rules)
ordered.move_to_end("default")
for key, items in ordered.items():
    rule_order_list += [item.name for item in items]
rule_order_list.append(fallback_qc_rule.name)
workflow._ruleorder.add(*rule_order_list)  # [::-1]


# This rule builds the energy calibration using the calibration dsp files
rule build_per_energy_calibration:
    input:
        files=os.path.join(
            filelist_path(config),
            "all-{experiment}-{period}-{run}-cal-" + f"{intier}.filelist",
        ),
        pulser=get_pattern_pars_tmp_channel(config, "tcm", "pulser_ids"),
        pht_dict=get_pattern_pars_tmp_channel(config, "pht", "qc"),
        inplots=get_pattern_plts_tmp_channel(config, "pht", "qc"),
        ctc_dict=ancient(
            lambda wildcards: ParsCatalog.get_par_file(
                psp_par_catalog if intier == "psp" else dsp_par_catalog,
                config,
                wildcards.timestamp,
                intier,
            )
        ),
    params:
        timestamp="{timestamp}",
        datatype="cal",
        channel="{channel}",
        tier="pht",
        dsp_table_name=lambda wildcards: get_table_name(
            metadata, config, "cal", wildcards.timestamp, wildcards.channel, "dsp"
        ),
    output:
        ecal_file=temp(get_pattern_pars_tmp_channel(config, "pht", "energy_cal")),
        results_file=temp(
            get_pattern_pars_tmp_channel(
                config, "pht", "energy_cal_objects", extension="pkl"
            )
        ),
        plot_file=temp(get_pattern_plts_tmp_channel(config, "pht", "energy_cal")),
    log:
        get_pattern_log_channel(config, "par_pht_energy_cal", time),
    group:
        "par-pht"
    resources:
        runtime=300,
    shell:
        execenv_pyexe(config, "par-geds-hit-ecal") + "--log {log} "
        "--datatype {params.datatype} "
        "--timestamp {params.timestamp} "
        "--channel {params.channel} "
        "--table-name {params.dsp_table_name} "
        "--configs {configs} "
        "--tier {params.tier} "
        "--metadata {meta} "
        "--plot-path {output.plot_file} "
        "--results-path {output.results_file} "
        "--save-path {output.ecal_file} "
        "--inplot-dict {input.inplots} "
        "--in-hit-dict {input.pht_dict} "
        "--ctc-dict {input.ctc_dict} "
        "--pulser-file {input.pulser} "
        "--files {input.files}"


part_pht_rules = {}
for key, dataset in part.datasets.items():
    for partition in dataset.keys():

        rule:
            input:
                files=part.get_filelists(partition, key, intier),
                pulser_files=[
                    str(file).replace("par_pht", "par_tcm")
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="pulser_ids",
                    )
                ],
                ecal_file=part.get_par_files(
                    pht_par_catalog,
                    partition,
                    key,
                    tier="pht",
                    name="energy_cal",
                ),
                eres_file=part.get_par_files(
                    pht_par_catalog,
                    partition,
                    key,
                    tier="pht",
                    name="energy_cal_objects",
                    extension="pkl",
                ),
                inplots=part.get_plt_files(
                    pht_par_catalog,
                    partition,
                    key,
                    tier="pht",
                    name="energy_cal",
                ),
            wildcard_constraints:
                channel=part.get_wildcard_constraints(partition, key),
            params:
                datatype="cal",
                channel="{channel}" if key == "default" else key,
                timestamp=part.get_timestamp(
                    pht_par_catalog, partition, key, tier="pht"
                ),
                dsp_table_name=lambda wildcards: get_table_name(
                    metadata,
                    config,
                    "cal",
                    part.get_timestamp(pht_par_catalog, partition, key, tier="pht"),
                    wildcards.channel,
                    "dsp",
                ),
            output:
                hit_pars=[
                    temp(file)
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="partcal",
                    )
                ],
                partcal_results=[
                    temp(file)
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="partcal_objects",
                        extension="pkl",
                    )
                ],
                plot_file=[
                    temp(file)
                    for file in part.get_plt_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="partcal",
                    )
                ],
            log:
                part.get_log_file(
                    pht_par_catalog,
                    partition,
                    key,
                    "pht",
                    time,
                    name="par_pht_partcal",
                ),
            group:
                "par-pht"
            resources:
                mem_swap=len(part.get_filelists(partition, key, intier)) * 15,
                runtime=300,
            shell:
                execenv_pyexe(config, "par-geds-pht-ecal-part") + "--log {log} "
                "--configs {configs} "
                "--datatype {params.datatype} "
                "--timestamp {params.timestamp} "
                "--inplots {input.inplots} "
                "--channel {params.channel} "
                "--table-name {params.dsp_table_name} "
                "--metadata {meta} "
                "--fit-results {output.partcal_results} "
                "--eres-file {input.eres_file} "
                "--hit-pars {output.hit_pars} "
                "--plot-file {output.plot_file} "
                "--ecal-file {input.ecal_file} "
                "--pulser-files {input.pulser_files} "
                "--input-files {input.files}"

        set_last_rule_name(
            workflow, f"{key}-{partition}-build_pht_energy_super_calibrations"
        )

        if key in part_pht_rules:
            part_pht_rules[key].append(list(workflow.rules)[-1])
        else:
            part_pht_rules[key] = [list(workflow.rules)[-1]]


# Merged energy and a/e supercalibrations to reduce number of rules as they have same inputs/outputs
# This rule builds the a/e calibration using the calibration dsp files for the whole partition
rule build_pht_energy_super_calibrations:
    input:
        files=os.path.join(
            filelist_path(config),
            "all-{experiment}-{period}-{run}-cal" + f"-{intier}.filelist",
        ),
        pulser_files=get_pattern_pars_tmp_channel(config, "tcm", "pulser_ids"),
        ecal_file=get_pattern_pars_tmp_channel(config, "pht", "energy_cal"),
        eres_file=get_pattern_pars_tmp_channel(
            config, "pht", "energy_cal_objects", extension="pkl"
        ),
        inplots=get_pattern_plts_tmp_channel(config, "pht", "energy_cal"),
    params:
        datatype="cal",
        channel="{channel}",
        timestamp="{timestamp}",
        dsp_table_name=lambda wildcards: get_table_name(
            metadata, config, "cal", wildcards.timestamp, wildcards.channel, "dsp"
        ),
    output:
        hit_pars=temp(get_pattern_pars_tmp_channel(config, "pht", "partcal")),
        partcal_results=temp(
            get_pattern_pars_tmp_channel(
                config, "pht", "partcal_objects", extension="pkl"
            )
        ),
        plot_file=temp(get_pattern_plts_tmp_channel(config, "pht", "partcal")),
    log:
        get_pattern_log_channel(config, "par_pht_partcal", time),
    group:
        "par-pht"
    resources:
        mem_swap=60,
        runtime=300,
    shell:
        execenv_pyexe(config, "par-geds-pht-ecal-part") + "--log {log} "
        "--configs {configs} "
        "--datatype {params.datatype} "
        "--timestamp {params.timestamp} "
        "--channel {params.channel} "
        "--table-name {params.dsp_table_name} "
        "--metadata {meta} "
        "--inplots {input.inplots} "
        "--fit-results {output.partcal_results} "
        "--eres-file {input.eres_file} "
        "--hit-pars {output.hit_pars} "
        "--plot-file {output.plot_file} "
        "--ecal-file {input.ecal_file} "
        "--pulser-files {input.pulser_files} "
        "--input-files {input.files}"


fallback_pht_rule = list(workflow.rules)[-1]

rule_order_list = []
ordered = OrderedDict(part_pht_rules)
ordered.move_to_end("default")
for key, items in ordered.items():
    rule_order_list += [item.name for item in items]
rule_order_list.append(fallback_pht_rule.name)
workflow._ruleorder.add(*rule_order_list)  # [::-1]

part_pht_rules = {}
for key, dataset in part.datasets.items():
    for partition in dataset.keys():

        rule:
            input:
                files=part.get_filelists(partition, key, intier),
                pulser_files=[
                    str(file).replace("par_pht", "par_tcm")
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="pulser_ids",
                    )
                ],
                ecal_file=part.get_par_files(
                    pht_par_catalog,
                    partition,
                    key,
                    tier="pht",
                    name="partcal",
                ),
                eres_file=part.get_par_files(
                    pht_par_catalog,
                    partition,
                    key,
                    tier="pht",
                    name="partcal_objects",
                    extension="pkl",
                ),
                inplots=part.get_plt_files(
                    pht_par_catalog,
                    partition,
                    key,
                    tier="pht",
                    name="partcal",
                ),
            wildcard_constraints:
                channel=part.get_wildcard_constraints(partition, key),
            params:
                datatype="cal",
                channel="{channel}" if key == "default" else key,
                timestamp=part.get_timestamp(
                    pht_par_catalog, partition, key, tier="pht"
                ),
                dsp_table_name=lambda wildcards: get_table_name(
                    metadata,
                    config,
                    "cal",
                    part.get_timestamp(pht_par_catalog, partition, key, tier="pht"),
                    wildcards.channel,
                    "dsp",
                ),
            output:
                hit_pars=[
                    temp(file)
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="aoecal",
                    )
                ],
                aoe_results=[
                    temp(file)
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="aoecal_objects",
                        extension="pkl",
                    )
                ],
                plot_file=[
                    temp(file)
                    for file in part.get_plt_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="aoecal",
                    )
                ],
            log:
                part.get_log_file(
                    pht_par_catalog,
                    partition,
                    key,
                    "pht",
                    time,
                    name="par_pht_aoe",
                ),
            group:
                "par-pht"
            resources:
                mem_swap=len(part.get_filelists(partition, key, intier)) * 15,
                runtime=300,
            shell:
                execenv_pyexe(config, "par-geds-pht-aoe") + "--log {log} "
                "--configs {configs} "
                "--metadata {meta} "
                "--datatype {params.datatype} "
                "--timestamp {params.timestamp} "
                "--inplots {input.inplots} "
                "--channel {params.channel} "
                "--table-name {params.dsp_table_name} "
                "--aoe-results {output.aoe_results} "
                "--eres-file {input.eres_file} "
                "--hit-pars {output.hit_pars} "
                "--plot-file {output.plot_file} "
                "--ecal-file {input.ecal_file} "
                "--pulser-files {input.pulser_files} "
                "--input-files {input.files}"

        set_last_rule_name(
            workflow, f"{key}-{partition}-build_pht_aoe_calibrations"
        )

        if key in part_pht_rules:
            part_pht_rules[key].append(list(workflow.rules)[-1])
        else:
            part_pht_rules[key] = [list(workflow.rules)[-1]]


# Merged energy and a/e supercalibrations to reduce number of rules as they have same inputs/outputs
# This rule builds the a/e calibration using the calibration dsp files for the whole partition
rule build_pht_aoe_calibrations:
    input:
        files=os.path.join(
            filelist_path(config),
            "all-{experiment}-{period}-{run}-cal-" + f"{intier}.filelist",
        ),
        pulser_files=get_pattern_pars_tmp_channel(config, "tcm", "pulser_ids"),
        ecal_file=get_pattern_pars_tmp_channel(config, "pht", "partcal"),
        eres_file=get_pattern_pars_tmp_channel(
            config, "pht", "partcal_objects", extension="pkl"
        ),
        inplots=get_pattern_plts_tmp_channel(config, "pht", "partcal"),
    params:
        datatype="cal",
        channel="{channel}",
        timestamp="{timestamp}",
        dsp_table_name=lambda wildcards: get_table_name(
            metadata, config, "cal", wildcards.timestamp, wildcards.channel, "dsp"
        ),
    output:
        hit_pars=temp(get_pattern_pars_tmp_channel(config, "pht", "aoecal")),
        aoe_results=temp(
            get_pattern_pars_tmp_channel(
                config, "pht", "aoecal_objects", extension="pkl"
            )
        ),
        plot_file=temp(get_pattern_plts_tmp_channel(config, "pht", "aoecal")),
    log:
        get_pattern_log_channel(config, "par_pht_aoe_cal", time),
    group:
        "par-pht"
    resources:
        mem_swap=60,
        runtime=300,
    shell:
        execenv_pyexe(config, "par-geds-pht-aoe") + "--log {log} "
        "--configs {configs} "
        "--metadata {meta} "
        "--datatype {params.datatype} "
        "--timestamp {params.timestamp} "
        "--inplots {input.inplots} "
        "--channel {params.channel} "
        "--table-name {params.dsp_table_name} "
        "--aoe-results {output.aoe_results} "
        "--eres-file {input.eres_file} "
        "--hit-pars {output.hit_pars} "
        "--plot-file {output.plot_file} "
        "--ecal-file {input.ecal_file} "
        "--pulser-files {input.pulser_files} "
        "--input-files {input.files}"


fallback_pht_rule = list(workflow.rules)[-1]

rule_order_list = []
ordered = OrderedDict(part_pht_rules)
ordered.move_to_end("default")
for key, items in ordered.items():
    rule_order_list += [item.name for item in items]
rule_order_list.append(fallback_pht_rule.name)
workflow._ruleorder.add(*rule_order_list)  # [::-1]

part_pht_rules = {}
for key, dataset in part.datasets.items():
    for partition in dataset.keys():

        rule:
            input:
                files=part.get_filelists(partition, key, intier),
                pulser_files=[
                    str(file).replace("par_pht", "par_tcm")
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="pulser_ids",
                    )
                ],
                ecal_file=part.get_par_files(
                    pht_par_catalog,
                    partition,
                    key,
                    tier="pht",
                    name="aoecal",
                ),
                eres_file=part.get_par_files(
                    pht_par_catalog,
                    partition,
                    key,
                    tier="pht",
                    name="aoecal_objects",
                    extension="pkl",
                ),
                inplots=part.get_plt_files(
                    pht_par_catalog,
                    partition,
                    key,
                    tier="pht",
                    name="aoecal",
                ),
            wildcard_constraints:
                channel=part.get_wildcard_constraints(partition, key),
            params:
                datatype="cal",
                channel="{channel}" if key == "default" else key,
                timestamp=part.get_timestamp(
                    pht_par_catalog, partition, key, tier="pht"
                ),
                dsp_table_name=lambda wildcards: get_table_name(
                    metadata,
                    config,
                    "cal",
                    part.get_timestamp(pht_par_catalog, partition, key, tier="pht"),
                    wildcards.channel,
                    "dsp",
                ),
            output:
                hit_pars=[
                    temp(file)
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                    )
                ],
                lq_results=[
                    temp(file)
                    for file in part.get_par_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                        name="objects",
                        extension="pkl",
                    )
                ],
                plot_file=[
                    temp(file)
                    for file in part.get_plt_files(
                        pht_par_catalog,
                        partition,
                        key,
                        tier="pht",
                    )
                ],
            log:
                part.get_log_file(
                    pht_par_catalog,
                    partition,
                    key,
                    "pht",
                    time,
                    name="par_pht_lq",
                ),
            group:
                "par-pht"
            resources:
                mem_swap=len(part.get_filelists(partition, key, intier)) * 15,
                runtime=300,
            shell:
                execenv_pyexe(config, "par-geds-pht-lq") + "--log {log} "
                "--configs {configs} "
                "--metadata {meta} "
                "--datatype {params.datatype} "
                "--timestamp {params.timestamp} "
                "--inplots {input.inplots} "
                "--channel {params.channel} "
                "--table-name {params.dsp_table_name} "
                "--lq-results {output.lq_results} "
                "--eres-file {input.eres_file} "
                "--hit-pars {output.hit_pars} "
                "--plot-file {output.plot_file} "
                "--ecal-file {input.ecal_file} "
                "--pulser-files {input.pulser_files} "
                "--input-files {input.files}"

        set_last_rule_name(workflow, f"{key}-{partition}-build_pht_lq_calibration")

        if key in part_pht_rules:
            part_pht_rules[key].append(list(workflow.rules)[-1])
        else:
            part_pht_rules[key] = [list(workflow.rules)[-1]]


# This rule builds the lq calibration using the calibration dsp files for the whole partition
rule build_pht_lq_calibration:
    input:
        files=os.path.join(
            filelist_path(config),
            "all-{experiment}-{period}-{run}-cal-" + f"{intier}.filelist",
        ),
        pulser_files=get_pattern_pars_tmp_channel(config, "tcm", "pulser_ids"),
        ecal_file=get_pattern_pars_tmp_channel(config, "pht", "aoecal"),
        eres_file=get_pattern_pars_tmp_channel(
            config, "pht", "aoecal_objects", extension="pkl"
        ),
        inplots=get_pattern_plts_tmp_channel(config, "pht", "aoecal"),
    params:
        datatype="cal",
        channel="{channel}",
        timestamp="{timestamp}",
        dsp_table_name=lambda wildcards: get_table_name(
            metadata, config, "cal", wildcards.timestamp, wildcards.channel, "dsp"
        ),
    output:
        hit_pars=temp(get_pattern_pars_tmp_channel(config, "pht")),
        lq_results=temp(
            get_pattern_pars_tmp_channel(config, "pht", "objects", extension="pkl")
        ),
        plot_file=temp(get_pattern_plts_tmp_channel(config, "pht")),
    log:
        get_pattern_log_channel(config, "par_pht_lq_cal", time),
    group:
        "par-pht"
    resources:
        mem_swap=60,
        runtime=300,
    shell:
        execenv_pyexe(config, "par-geds-pht-lq") + "--log {log} "
        "--configs {configs} "
        "--metadata {meta} "
        "--datatype {params.datatype} "
        "--timestamp {params.timestamp} "
        "--inplots {input.inplots} "
        "--channel {params.channel} "
        "--table-name {params.dsp_table_name} "
        "--lq-results {output.lq_results} "
        "--eres-file {input.eres_file} "
        "--hit-pars {output.hit_pars} "
        "--plot-file {output.plot_file} "
        "--ecal-file {input.ecal_file} "
        "--pulser-files {input.pulser_files} "
        "--input-files {input.files}"


fallback_pht_rule = list(workflow.rules)[-1]

rule_order_list = []
ordered = OrderedDict(part_pht_rules)
ordered.move_to_end("default")
for key, items in ordered.items():
    rule_order_list += [item.name for item in items]
rule_order_list.append(fallback_pht_rule.name)
workflow._ruleorder.add(*rule_order_list)  # [::-1]
