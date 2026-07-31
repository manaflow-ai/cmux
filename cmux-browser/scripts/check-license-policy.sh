#!/usr/bin/env bash
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later

# Keep the desktop Browser on the reviewed GPL policy while allowing
# third-party files to retain their own licenses. AGPL may be considered for a
# separately reviewed hosted component, but it is not a desktop Browser source
# license.
set -euo pipefail

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$BROWSER_ROOT/.." && pwd)"
FAILURES=0

report_failure() {
  echo "ERROR: $*" >&2
  FAILURES=$((FAILURES + 1))
}

require_text() {
  local path="$1"
  local text="$2"
  local description="$3"

  if ! grep -Fq -- "$text" "$path"; then
    report_failure "$description: $path"
  fi
}

require_package_license() {
  local path="$1"

  if ! grep -Eq \
    '"license"[[:space:]]*:[[:space:]]*"GPL-3\.0-or-later"' \
    "$path"; then
    report_failure \
      "desktop package license must remain GPL-3.0-or-later: $path"
  fi
}

is_source_file() {
  case "$1" in
    *.c|*.cc|*.cpp|*.cxx|*.h|*.hh|*.hpp|*.m|*.mm|*.sh|*.py|*.rs|*.swift|*.gn|*.gni|*.mojom)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_gpl_source_header() {
  local path="$1"

  if ! head -n 12 "$path" | grep -Eq \
    'SPDX-License-Identifier:[[:space:]]*GPL-3\.0-or-later([[:space:]]*\*/)?[[:space:]]*$'; then
    report_failure \
      "Manaflow Browser source must declare GPL-3.0-or-later: $path"
  fi
}

require_package_license "$REPO_ROOT/package.json"
require_package_license "$REPO_ROOT/web/package.json"

require_text \
  "$REPO_ROOT/LICENSE" \
  "GPL-3.0-or-later" \
  "root project license declaration is missing"
require_text \
  "$BROWSER_ROOT/AGENTS.md" \
  "Manaflow rights-controlled files use GPL-3.0-or-later." \
  "Browser contributor policy is missing the GPL rule"
require_text \
  "$BROWSER_ROOT/README.md" \
  "AGPL is not the default for the desktop Browser." \
  "desktop AGPL exclusion is missing"

# Reject AGPL source declarations anywhere in the Browser tree. Explanatory
# mentions in policy documents remain allowed.
AGPL_SPDX_PATTERN='SPDX-License-Identifier:[[:space:]]*.*A''GPL-[0-9]'
while IFS= read -r -d '' path; do
  if grep -Eqi \
    "$AGPL_SPDX_PATTERN" \
    "$path"; then
    report_failure "AGPL SPDX declaration is outside desktop policy: $path"
  fi
done < <(find "$BROWSER_ROOT" -type f -print0)

# These are Manaflow-owned source areas. Third-party and derived files outside
# them keep their upstream licenses and are governed by the provenance ledger.
MANAFLOW_SOURCE_ROOTS=(
  "$BROWSER_ROOT/scripts"
  "$BROWSER_ROOT/overlay/chrome/browser/cmux_term"
  "$BROWSER_ROOT/overlay/chrome/services/cmux_terminal_renderer"
)

for source_root in "${MANAFLOW_SOURCE_ROOTS[@]}"; do
  if [[ ! -d "$source_root" ]]; then
    continue
  fi

  while IFS= read -r -d '' path; do
    if is_source_file "$path"; then
      require_gpl_source_header "$path"
    fi
  done < <(find "$source_root" -type f -print0)
done

if ((FAILURES > 0)); then
  echo "FAIL Browser desktop license policy ($FAILURES issue(s))" >&2
  exit 1
fi

echo "PASS Browser desktop license policy"
