cd webviews
C=src/agent-session/acpmux/question/hatQuestions.css
echo "== FIX"; bun test test/hat-questions-dismiss-muted.test.ts 2>&1 | grep -E "^\((pass|fail)\)|Expected|Received"
sed -i 's/^\.acpmux-hat-questions__dismiss\.ui-button\.ui-btn {/.acpmux-hat-questions__dismiss {/' $C
grep -c "^\.acpmux-hat-questions__dismiss {" $C
echo "== REVERTED"; bun test test/hat-questions-dismiss-muted.test.ts 2>&1 | grep -E "^\((pass|fail)\)|Expected|Received"
git checkout -- $C
bunx vp fmt --check test/hat-questions-dismiss-muted.test.ts $C 2>&1 | tail -1
bun scripts/check-fixed-waits.ts | tail -1
