#!/usr/bin/env bash
# The vendored ACP v1 schema (schema/acp/v1/, its tag and sha256 in PIN).
#   acp-schema.sh latest     print the pinned tag and the newest upstream schema-v1.* tag
#   acp-schema.sh pin TAG    download TAG's schema.json and meta.json and rewrite PIN
# The conformance tests are tests/hub_integration/acp_schema.rs.
set -euo pipefail
repo=agentclientprotocol/agent-client-protocol
dir="$(cd "$(dirname "$0")/.." && pwd)/schema/acp/v1"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
pinned="$(sed -n 's/^tag=//p' "$dir/PIN")"

case "${1:-latest}" in
latest)
  # Tags, not the releases API: no token or API quota.
  newest="$(git ls-remote --tags --refs "https://github.com/$repo" 'schema-v1.*' |
    sed 's|.*refs/tags/||' | grep -E '^schema-v1\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  echo "pinned: $pinned"
  echo "newest: $newest"
  [ "$pinned" = "$newest" ] || echo "bump: $0 pin $newest"
  ;;
pin)
  tag="${2:?usage: $0 pin TAG}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  for f in schema.json meta.json; do
    curl -fsSL -o "$tmp/$f" "https://github.com/$repo/releases/download/$tag/$f"
  done
  mv "$tmp/schema.json" "$tmp/meta.json" "$dir/"
  sed -i.bak -e "s/^tag=.*/tag=$tag/" \
    -e "s/^schema.json sha256=.*/schema.json sha256=$(sha256 "$dir/schema.json")/" \
    -e "s/^meta.json sha256=.*/meta.json sha256=$(sha256 "$dir/meta.json")/" \
    "$dir/PIN"
  rm -f "$dir/PIN.bak"
  echo "pinned $tag; run the acp_schema tests"
  ;;
*) echo "usage: $0 latest | pin TAG" >&2; exit 2 ;;
esac
