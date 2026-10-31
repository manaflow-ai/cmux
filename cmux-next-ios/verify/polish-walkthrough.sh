#!/bin/zsh
# Full-app walkthrough recordings for the polish pass, on one headless
# simulator, in both appearances. Build first (verify/build.sh).
# usage: verify/polish-walkthrough.sh <udid> <label-prefix> [segments...]
# Segments: onboarding tour-a tour-b tour-c ws-terminal (default: all).
set -e
U=$1; P=$2; shift 2
S=${0:a:h}/scripts
segments=($@); (( $#segments )) || segments=(onboarding tour-a tour-b tour-c ws-terminal)
typeset -A secs=(onboarding 20 tour-a 50 tour-b 80 tour-c 32 ws-terminal 52)
for mode in dark light; do
  for seg in $segments; do
    if [[ $seg == onboarding ]]; then
      CMUX_MOBILE_CLEAR_AUTH=1 CMUX_MOBILE_SETUP=false $S/record_flow.sh $U $P-$seg-$mode polish ${secs[$seg]} $mode -cmux-mobile-demo onboarding
    else
      $S/record_flow.sh $U $P-$seg-$mode polish ${secs[$seg]} $mode -cmux-mobile-demo $seg
    fi
  done
done
