#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'require-current-main: %s\n' "$*" >&2
  exit 1
}

: "${GITHUB_REF:?GITHUB_REF is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

[[ "$GITHUB_REF" == "refs/heads/main" ]] ||
  die "expected a main branch event, got $GITHUB_REF"
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  die "GITHUB_SHA is not a full commit SHA: $GITHUB_SHA"

main_sha="$({
  git ls-remote --heads origin refs/heads/main
} | awk '
  NF >= 1 { print $1; count++ }
  END { if (count != 1) exit 1 }
')" || die "could not resolve protected main from origin"

[[ "$main_sha" =~ ^[0-9a-f]{40}$ ]] ||
  die "origin/main did not resolve to a full commit SHA: $main_sha"
[[ "$GITHUB_SHA" == "$main_sha" ]] ||
  die "event SHA $GITHUB_SHA is not current protected main $main_sha"

printf 'require-current-main: protected main is current at %s\n' "$GITHUB_SHA"
