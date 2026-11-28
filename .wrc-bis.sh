#!/bin/bash
# bisect points: reverse-apply each patch, run the files, restore. Prints a verdict per point; exit is not a test verdict.
set -u
FILES="$1"; shift
cd webviews && bun install --frozen-lockfile > /tmp/wrc-install.log 2>&1 || { tail -30 /tmp/wrc-install.log; exit 3; }
cd ..
for P in "$@"; do
  echo "##### POINT $P"
  if ! git apply -R --whitespace=nowarn ".bis/$P.patch"; then echo "POINT $P APPLY FAILED"; continue; fi
  ( cd webviews && CMUX_WEB_TEST_FILES="$(tr ',' '\n' <<<"$FILES")" bash ../scripts/ci/run-webviews-tests.sh ) > /tmp/bis-$P.log 2>&1
  echo "POINT $P exit=$?"
  grep -E "^FAIL test/|^\(fail\)" /tmp/bis-$P.log | sort -u
  git apply --whitespace=nowarn ".bis/$P.patch" || { echo "RESTORE FAILED at $P"; exit 5; }
done
