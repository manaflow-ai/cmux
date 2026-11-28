set -euo pipefail
export PATH="$PWD/.default-speed-tools/bin:$PATH"
bench="$PWD/scripts/bench/phone-default-speed"
binary="$bench/target/release/cmux-phone-default-speed"
TIMEFORMAT='wall=%R user=%U sys=%S'
{ time timeout 180 env -u CI "$binary" update; } > .default-speed-tools/update.log 2>&1
{ time timeout 180 "$binary" check; } > .default-speed-tools/check.log 2>&1
{ time timeout 180 "$binary" check; } > .default-speed-tools/check-repeat.log 2>&1
mkdir -p scripts/bench/tests/fixtures/phone-default-speed
cp .default-speed-tools/check.log scripts/bench/tests/fixtures/phone-default-speed/check.log
cat .default-speed-tools/update.log .default-speed-tools/check.log .default-speed-tools/check-repeat.log
python3 scripts/bench/tests/test_phone_default_speed.py
