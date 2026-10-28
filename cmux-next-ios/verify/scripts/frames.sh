#!/bin/zsh
# frames.sh <video.mp4> <start-seconds> <duration> <outdir> [scale-width]
# Extracts every recorded frame (variable frame rate, no duplication) in the
# window and names each by its presentation time in milliseconds.
set -e
V=$1; S=$2; D=$3; O=$4; W=${5:-402}
mkdir -p $O
ffmpeg -nostdin -v error -ss $S -t $D -i $V -vf "scale=$W:-1" -fps_mode passthrough -frame_pts 1 -enc_time_base 1/1000 $O/f_%08d.png
ls $O | wc -l
