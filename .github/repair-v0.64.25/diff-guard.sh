#!/usr/bin/env bash
# Proves the repaired bundle differs from the shipped one only in the patched
# cmux-cua binaries and the signatures, tickets and helper Info.plist nonce
# that re-signing and notarization necessarily rewrite.
set -euo pipefail
ORIG="$1"
NEW="$2"
OUT="$3"
mkdir -p "$OUT"
manifest() {
  ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 )
}
manifest "$ORIG" > "$OUT/original-files.txt"
manifest "$NEW" > "$OUT/repaired-files.txt"
if ! diff <(sed -E 's/^[0-9a-f]{64}  //' "$OUT/original-files.txt") \
          <(sed -E 's/^[0-9a-f]{64}  //' "$OUT/repaired-files.txt"); then
  echo "::error::file list changed"
  exit 1
fi
changed="$( (diff "$OUT/original-files.txt" "$OUT/repaired-files.txt" || true) \
  | sed -nE 's/^> [0-9a-f]{64}  //p')"
echo "changed files:"
printf '%s\n' "$changed"
helper='\./Contents/Library/cmux Computer Use\.app/Contents'
allowed="^(\./Contents/(MacOS/cmux|_CodeSignature/CodeResources|CodeResources|Resources/bin/cmux-cua)|$helper/(MacOS/cmux-cua|_CodeSignature/CodeResources|CodeResources|Info\.plist))\$"
unexpected="$(grep -Ev "$allowed" <<<"$changed" || true)"
if [ -n "$unexpected" ]; then
  echo "::error::unexpected changed files:"
  printf '%s\n' "$unexpected"
  exit 1
fi
for required in './Contents/Resources/bin/cmux-cua' \
  './Contents/Library/cmux Computer Use.app/Contents/MacOS/cmux-cua'; do
  grep -qxF "$required" <<<"$changed" || { echo "::error::$required was not patched"; exit 1; }
done
# The helper Info.plist may differ only in the per-submission notarization nonce.
python3 - "$ORIG" "$NEW" <<'PY'
import plistlib, sys
rel = "Contents/Library/cmux Computer Use.app/Contents/Info.plist"
a = plistlib.load(open(f"{sys.argv[1]}/{rel}", "rb"))
b = plistlib.load(open(f"{sys.argv[2]}/{rel}", "rb"))
for d in (a, b):
    d.pop("CMUXNotarizationSubmission", None)
if a != b:
    sys.exit(f"error: helper Info.plist changed beyond CMUXNotarizationSubmission")
print("helper Info.plist: only CMUXNotarizationSubmission differs")
PY
# Signing identity, requirements and entitlements must match the shipped code.
sig() {
  local target="$1" certs
  certs="$(mktemp -d)"
  ( cd "$certs" && /usr/bin/codesign -d --extract-certificates=cert "$target" >/dev/null 2>&1 )
  echo "leaf-cert-sha256=$(shasum -a 256 < "$certs/cert0" | awk '{print $1}')"
  rm -rf "$certs"
  /usr/bin/codesign -d --entitlements - --xml "$target" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true
  /usr/bin/codesign -d -r- "$target" 2>&1 | grep '^designated' || true
  /usr/bin/codesign -dvv "$target" 2>&1 \
    | sed -nE '/^(Identifier|Format|Authority|TeamIdentifier|Runtime Version)=/p; s/^CodeDirectory .*(flags=[^ ]+).*/\1/p'
}
for rel in . Contents/Resources/bin/cmux-cua "Contents/Library/cmux Computer Use.app"; do
  if ! diff -u <(sig "$ORIG/$rel") <(sig "$NEW/$rel"); then
    echo "::error::signature metadata changed for $rel"
    exit 1
  fi
  echo "signature metadata unchanged: $rel"
done
