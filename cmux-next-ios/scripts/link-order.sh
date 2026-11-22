#!/usr/bin/env bash
# The app's linker order file (ORDER_FILE in project.yml): every symbol that the Rust library
# (CmuxMobileLinkFFIFFI) and libghostty define, in their own order. ld moves each listed atom to
# the start of its section, so in __text, __const, __data and the rest the Rust and Ghostty code
# and data come first and the app's Swift comes after them. A change to Swift then moves none of
# their bytes in the executable, and an iPhone update that only changes Swift shares them with
# the build before (Leo, 2026-11-22: "having those downloads/updates be more incremental").
#
# Run as the CmuxMobileApp target's pre-build script phase: input 0 is the Rust static library,
# input 1 libghostty, both as Xcode copies them out of their xcframeworks for the platform being
# built; output 0 the order file. Without Xcode: link-order.sh RUST_LIB GHOSTTY_LIB OUT.
#
# Each library's symbols keep the library's own order (archive members in turn, each member's
# symbols by address), so their code stays laid out as before, only ahead of the Swift.
# Kept: global and private-extern names (leading _) and Rust's l_anon.* constants. Left out:
# assembler temporaries (ltmp*, L*) and C string labels (l_.str*), whose names repeat in every
# object, so naming them would pull Swift-side atoms of the same name to the front too.
set -euo pipefail

rust_lib="${1:-${SCRIPT_INPUT_FILE_0:?}}"
ghostty_lib="${2:-${SCRIPT_INPUT_FILE_1:?}}"
out="${3:-${SCRIPT_OUTPUT_FILE_0:?}}"

nm_tool=(nm)
command -v xcrun >/dev/null 2>&1 && nm_tool=(xcrun nm)

tmp="$out.tmp.$$"
trap 'rm -f "$tmp"' EXIT
mkdir -p "$(dirname "$out")"
{
  for lib in "$rust_lib" "$ghostty_lib"; do
    [[ -f "$lib" ]] || { echo "error: link-order.sh: no library at $lib" >&2; exit 1; }
    # -U defined only, -n by address within each member, -m for the section and scope
    # (archive members print in archive order). --no-llvm-bc: Rust's std members also carry
    # LLVM bitcode from a newer LLVM than Xcode's, which nm would otherwise try to read and
    # fail on ("Unknown attribute kind"); the linker uses only their machine code.
    "${nm_tool[@]}" --no-llvm-bc -U -n -m "$lib" | awk '
      # "0000000000000000 (__TEXT,__text) non-external _foo": the name is the last field.
      NF >= 4 && $2 ~ /^\(/ {
        name = $NF
        if (name ~ /^_/ || name ~ /^l_anon\./) print name
      }'
  done
} | awk '!seen[$0]++' >"$tmp"
[[ -s "$tmp" ]] || { echo "error: link-order.sh: no symbols in $rust_lib or $ghostty_lib" >&2; exit 1; }
mv -f "$tmp" "$out"
trap - EXIT
echo "link-order.sh: $(wc -l <"$out" | tr -d ' ') symbols -> $out"
