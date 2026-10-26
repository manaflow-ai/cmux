#!/usr/bin/env bash
# List alignment rig: build an iOS ref on the mini and measure it there, results to the laptop.
#
#   run.sh build SHA NAME          git archive SHA -> mini:~/hdralign/NAME/src, Demo simulator build
#   run.sh measure NAME [OUT]      measure.py on mini:~/hdralign/NAME's app, copy to OUT
#                                  (default ~/cmux-mobile-builds/20261023-hdralign-evidence/NAME)
#   run.sh compare BEFORE AFTER    compare.py of two local result folders
#
# The rig (hidden tagged Mac in mini:~/hdralign/rigmac, simulator cmux-hdralign) must be up:
#   ssh $HOST 'cd ~/hdralign/rigmac && MULTIMAC_PHONE=cmux-hdralign python3 rig_hdr.py launch'
#   ssh $HOST 'python3 ~/hdralign/tools/cmux-next-ios/verify/alignment/seed.py ~/hdralign/rigmac'
# Extra measure.py options go in MEASURE_ARGS (e.g. "--screens workspaces,settings --sizes large").
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
HOST=${HDRALIGN_HOST:-mini-cmux11s-mac-mini}
DD=/Applications/Xcode_26.6.app/Contents/Developer

sync_tools() {
  ssh "$HOST" 'mkdir -p ~/hdralign/tools/cmux-next-ios/verify/alignment ~/hdralign/tools/cmux-next-ios/verify/e2e'
  scp -q "$here"/*.py "$here"/*.swift "$here"/*.sh "$HOST":hdralign/tools/cmux-next-ios/verify/alignment/
  scp -q "$repo"/cmux-next-ios/verify/e2e/{sim.py,journey.py,mac.py,ocr.swift} "$HOST":hdralign/tools/cmux-next-ios/verify/e2e/
}

case "${1:-}" in
  build)
    sha=$(git -C "$repo" rev-parse "${2:?SHA}^{commit}"); name=${3:?NAME}
    key=$(printf '%s\n' "$(git -C "$repo" rev-parse "$sha:cmux-next-ios/rust")" \
      "$(git -C "$repo" rev-parse "$sha:cmux-tui/crates/cmux-wg")" \
      "$(git -C "$repo" rev-parse "$sha:cmux-tui/crates/cmux-transport")" | shasum | cut -c1-16)
    sync_tools
    ssh "$HOST" "rm -rf ~/hdralign/$name/src && mkdir -p ~/hdralign/$name/src"
    git -C "$repo" archive --format=tar "$sha" cmux-next-ios Packages vendor/stack-auth-swift-sdk-prerelease AppIcon.icon \
      ':(exclude)cmux-next-ios/verify/design' ':(exclude)Packages/macOS' | gzip -1 \
      | ssh "$HOST" "tar -xz -C ~/hdralign/$name/src && echo $sha > ~/hdralign/$name/SHA"
    ssh "$HOST" "XCF_KEY=$key zsh ~/hdralign/tools/cmux-next-ios/verify/alignment/ios-build.sh ~/hdralign/$name"
    ;;
  measure)
    name=${2:?NAME}; out=${3:-$HOME/cmux-mobile-builds/20261023-hdralign-evidence/$name}
    sync_tools
    ssh "$HOST" "export DEVELOPER_DIR=$DD; cd ~/hdralign/tools/cmux-next-ios/verify/alignment && rm -rf ~/hdralign/out/$name && \
      python3 measure.py --app ~/hdralign/$name/dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app \
        --out ~/hdralign/out/$name --label \"$name \$(cat ~/hdralign/$name/SHA)\" ${MEASURE_ARGS:-}"
    mkdir -p "$out"
    rsync -a "$HOST":hdralign/out/"$name"/ "$out"/
    echo "$out/summary.md"
    ;;
  compare)
    python3 "$here/compare.py" "${2:?BEFORE}" "${3:?AFTER}"
    ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
