#!/usr/bin/env bash
echo "host $(hostname) nproc $(nproc)"
bash .ct-probe/run.sh wk-off wk wk-off wk wk-off wk
