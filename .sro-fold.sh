#!/bin/bash
cd webviews
T="test/turn-end-fold-browser.test.ts test/turn-end-fold-clock-growth-browser.test.ts"
for t in $T; do echo "### head $t"; bun test $t 2>&1 | grep -E "^\(fail\)| pass$| fail$|error:|Expected|Received|expect\(" | head -30; done
cd ..; git fetch -q --depth=1 origin 1f026f81276 2>/dev/null; git checkout -q 1f026f81276 -- webviews/src && echo "BASE-CHECKED-OUT $(git diff --stat HEAD -- webviews/src | tail -1)"
cd webviews
for t in $T; do echo "### base $t"; bun test $t 2>&1 | grep -E "^\(fail\)| pass$| fail$|error:" | head -12; done
