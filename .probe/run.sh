#!/bin/bash
# throwaway probe: repeat the 360px wrapping cases on base and with each candidate reverted
cd "$(dirname "$0")/../webviews"
node scripts/pages/gen-strings.mjs >/dev/null
for v in base de9d3bb3c1ce de9d3bb3c1ce+b3571f2dc4f de9d3bb3c1ce+cc410eb9474; do
  git -C .. checkout -q -- webviews/src
  if [ "$v" != base ]; then ok=1; for c in ${v//+/ }; do git -C .. apply -R ".probe/$c.patch" || ok=0; done; [ $ok = 1 ] || { echo "VARIANT $v apply failed"; continue; }; fi
  p=0; f=0
  for i in 1 2 3 4 5; do
    out=$(CMUX_BROWSER_LANE=1 bun test test/queued-user-footer.test.ts -t "360px, wrapping" 2>&1)
    p=$((p + $(grep -c '^(pass)' <<<"$out"))); f=$((f + $(grep -c '^(fail)' <<<"$out")))
    grep -o '"before":{[^}]*"footerTop":[0-9.]*' <<<"$out" | sed 's/.*footerTop/footerTop/' | tr '\n' ' '
  done
  echo; echo "VARIANT $v pass=$p fail=$f"
done
git -C .. checkout -q -- webviews/src
