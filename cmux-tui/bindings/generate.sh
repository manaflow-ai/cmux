#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MUX_DIR/.." && pwd)"
PROMPT_DIR="$SCRIPT_DIR/.generated-prompts"

SPEC_FILES=(
  "$MUX_DIR/spec/README.md"
  "$MUX_DIR/spec/commands.md"
  "$MUX_DIR/spec/events.md"
  "$MUX_DIR/spec/transports.md"
  "$MUX_DIR/spec/cli.md"
  "$MUX_DIR/spec/bindings.md"
)

GENERATE_LANGS=(python typescript rust go java)
STUB_LANGS=()

mkdir -p "$PROMPT_DIR"

assemble_prompt() {
  local lang="$1"
  local out_dir="$2"
  local style="$SCRIPT_DIR/styles/$lang.md"
  local prompt="$PROMPT_DIR/$lang.prompt.md"

  if [[ ! -f "$style" ]]; then
    echo "missing style sheet: $style" >&2
    exit 2
  fi

  {
    echo "# cmux-tui $lang binding generation"
    echo
    echo "You are generating the $lang binding for cmux-tui."
    echo
    echo "Rules:"
    echo "- Emit files only under $out_dir/."
    echo "- This is a temporary output directory. The harness swaps it into cmux-tui/bindings/$lang/ only after generation succeeds."
    echo "- Regeneration must overwrite stale generated files inside the temporary output directory."
    echo "- Follow the style sheet exactly."
    echo "- Implement protocol-v5 commands marked implemented, plus consumer-side implemented move commands."
    echo "- Preserve command names, params, result shapes, event names, and error behavior from the spec."
    echo "- Do not implement proposed commands unless the style sheet explicitly asks for version-gated stubs."
    echo
    echo "## Language style sheet"
    cat "$style"
    echo
    for spec in "${SPEC_FILES[@]}"; do
      echo
      echo "## Spec: ${spec#$REPO_ROOT/}"
      cat "$spec"
    done
  } > "$prompt"

  printf '%s\n' "$prompt"
}

generate_lang() {
  local lang="$1"
  local out="$SCRIPT_DIR/$lang"
  local tmp
  local tmp_rel
  local prompt

  tmp="$(mktemp -d "$SCRIPT_DIR/.tmp-$lang.XXXXXX")"
  tmp_rel="${tmp#$REPO_ROOT/}"
  prompt="$(assemble_prompt "$lang" "$tmp_rel")"

  echo "Generating $lang binding into temporary directory $tmp_rel"
  if codex exec --cd "$REPO_ROOT" "$(cat "$prompt")"; then
    rm -rf "$out"
    mv "$tmp" "$out"
    echo "Installed $lang binding into ${out#$REPO_ROOT/}"
  else
    rm -rf "$tmp"
    echo "Generation failed for $lang; existing ${out#$REPO_ROOT/} left untouched" >&2
    exit 1
  fi
}

for lang in "${GENERATE_LANGS[@]}"; do
  generate_lang "$lang"
done

for lang in "${STUB_LANGS[@]}"; do
  mkdir -p "$SCRIPT_DIR/$lang"
  echo "Skipping $lang generation this round; style sheet is present at cmux-tui/bindings/styles/$lang.md"
done

cat <<'EOF'

Generation complete.

Run conformance with:
  python3 cmux-tui/bindings/conformance/runner.py
EOF
