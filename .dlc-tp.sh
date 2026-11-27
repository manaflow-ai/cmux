#!/usr/bin/env bash
# RUSTC_WRAPPER: -Z time-passes for the two crates the edit rebuilds (wrapper args stay out of cargo's fingerprint).
rustc="$1"; shift
case " $* " in *" --crate-name cmux_tui_core "*|*" --crate-name cmux_tui "*)
  name=$(printf '%s\n' "$@" | grep -A1 -x -- --crate-name | tail -1); typ=$(printf '%s\n' "$@" | grep -A1 -x -- --crate-type | tail -1)
  RUSTC_BOOTSTRAP=1 exec "$rustc" "$@" -Z time-passes 2> >(tee -a "/tmp/tp-$name-$typ.txt" >&2) ;;
esac
exec "$rustc" "$@"
