#!/usr/bin/env bash
# Checks that the shared iOS packages cmux-next-ios uses are byte-identical to
# their upstream branches. cmux-next-ios never patches them; anything it needs
# goes in its own host code or, as a proposal, in cmux-next-ios/verify/*-upstream-requests.md.
#
#   Packages/iOS/CmuxTabsKit       == origin/feat-cmux-next-tabs-kit
#   Packages/iOS/CmuxConversation  == origin/feat-imsg-parity-gui
#
# usage: cmux-next-ios/scripts/check-tabskit-sync.sh [--ref <git ref>] [--no-fetch] [--quiet]
#   --ref       the commit to check (default HEAD)
#   --no-fetch  compare with the local remote-tracking refs as they are
#   --quiet     print only on drift
#
# Exit status: 0 all identical, 1 a package differs, 2 an upstream ref is missing.
# To sync one: git checkout origin/<branch> -- Packages/iOS/<Package>
# (and delete files the upstream no longer has; the check lists them).
set -euo pipefail

ref=HEAD fetch=1 quiet=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref=$2; shift 2 ;;
    --no-fetch) fetch=0; shift ;;
    --quiet) quiet=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
pairs=(
  "Packages/iOS/CmuxTabsKit feat-cmux-next-tabs-kit"
  "Packages/iOS/CmuxConversation feat-imsg-parity-gui"
)

if [[ $fetch == 1 ]]; then
  branches=(); for p in "${pairs[@]}"; do branches+=("${p#* }"); done
  for b in "${branches[@]}"; do
    git -C "$repo" fetch --quiet origin "+refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null \
      || echo "warning: could not fetch origin/$b; comparing with the local ref" >&2
  done
fi

status=0
for p in "${pairs[@]}"; do
  path=${p% *} branch=${p#* } upstream="origin/${p#* }"
  if ! up=$(git -C "$repo" rev-parse --verify --quiet "$upstream^{commit}"); then
    echo "error: $upstream is missing (git fetch origin $branch)" >&2
    status=2; continue
  fi
  ours=$(git -C "$repo" rev-parse "$ref:$path" 2>/dev/null || echo missing)
  theirs=$(git -C "$repo" rev-parse "$upstream:$path" 2>/dev/null || echo missing)
  if [[ "$ours" == "$theirs" ]]; then
    [[ $quiet == 1 ]] || echo "ok: $path matches $upstream (${up:0:12})"
  else
    echo "DRIFT: $path at $ref differs from $upstream (${up:0:12} $(git -C "$repo" log -1 --format=%s "$up"))"
    git -C "$repo" diff --stat "$up" "$ref" -- "$path" | sed 's/^/  /'
    echo "  sync: git checkout $upstream -- $path   (then remove files listed above that $upstream lacks)"
    [[ $status == 2 ]] || status=1
  fi
done
exit $status
