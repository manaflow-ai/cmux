cd webviews
T=test/composer-original-failure-race.test.tsx
F=src/agent-session/acpmux/composer/attachmentIntakeModel.ts
bun test $T 2>&1 | grep -E "\((pass|fail)\)|error|Expected|Received" | head -8
pass=0; fail=0
for i in $(seq 1 25); do if bun test $T >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); fi; done
echo "== FIX pass=$pass fail=$fail"
bun test test/composer-original-failure.test.tsx $T 2>&1 | grep -E "^ *[0-9]+ (pass|fail)"
sed -i 's/(id) => everDrawn.current.has(id) \&\& !attachments/(id) => !attachments/' $F
echo "replaced=$(grep -c '(id) => !attachments' $F)"
pass=0; fail=0
for i in $(seq 1 10); do if bun test $T >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); fi; done
echo "== NO GUARD pass=$pass fail=$fail"
bun test $T 2>&1 | grep -E "Expected|Received" | head -4
git checkout -- $F
bunx tsc -p tsconfig.json --noEmit >/tmp/tsc.txt 2>&1; echo "tsc exit $?"; head -3 /tmp/tsc.txt
bunx vp fmt --check $T 2>&1 | tail -1
bun scripts/check-fixed-waits.ts | tail -1
