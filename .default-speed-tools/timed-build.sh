set -euo pipefail
TIMEFORMAT="build wall=%R user=%U sys=%S"
time bash .default-speed-tools/build.sh
