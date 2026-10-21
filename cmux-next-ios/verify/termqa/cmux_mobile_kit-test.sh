#!/bin/zsh
# cmux_mobile_kit-test.sh FILTER: runs CmuxMobileKit's swift tests for FILTER on mini-cmux11s
# (never on the laptop). Syncs CmuxMobileKit/{Sources,Tests,Package.swift} of this
# checkout into ~/termqa-test/cmux-next-ios/CmuxMobileKit and touches them (rsync keeps
# mtimes, and SwiftPM could reuse a newer build).
set -euo pipefail
here=${0:a:h}
kit=${here:h:h}/CmuxMobileKit
host=${CMUX_MOBILE_KIT_TEST_HOST:-mini-cmux11s-mac-mini}
dir=${CMUX_MOBILE_KIT_TEST_DIR:-termqa-test}  # one per concurrent agent
ssh $host "mkdir -p ~/${dir}/cmux-next-ios/CmuxMobileKit"
rsync -a --delete $kit/Sources $kit/Tests $kit/Package.swift ${host}:${dir}/cmux-next-ios/CmuxMobileKit/
ssh $host "mkdir -p ~/${dir}/cmux-next-ios/CmuxMobileKit && cd ~/${dir}/cmux-next-ios/CmuxMobileKit && find Sources Tests -name '*.swift' -exec touch {} + && swift test --filter '${1:?filter}' 2>&1 | grep -E 'error:|✘|failed|passed after|Test run with|issue' | tail -${2:-40}"
