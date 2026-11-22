#!/bin/bash
# Runs scenarios detached on the host: runbg.sh <out dir> <scenario...>; writes <out>/run.log, ends with "RUN-DONE rc".
OUT=$1; shift; mkdir -p $OUT
nohup bash -c "OUT=$OUT bash ~/imsgreply/scenarios.sh $* > $OUT/run.log 2>&1; echo RUN-DONE \$? >> $OUT/run.log" >/dev/null 2>&1 < /dev/null &
