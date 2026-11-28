#!/usr/bin/env bash
# Give this runner instance a CARGO_HOME of its own when several runner
# instances share one HOME (the owned Macs run 7-9 runners as one user).
#
# With one shared ~/.cargo, Swatinem/rust-cache's post step in one job
# (cleanRegistry with cache-all-crates: false) deletes every crate source in
# ~/.cargo/registry/src while a cargo build in a sibling runner still compiles
# from it. That build then fails with "could not execute process `rustc ...`
# (os error 2)" or "could not parse/generate dep info ... (os error 2)":
#   ultra1-glaeda-2 cleaned at 12:20:25.0Z, ultra1-glaeda-1 failed at 12:20:25.5Z
#   (run 42477732646); ultra2-glaeda-5 cleaned at 13:06:16.9Z, ultra2-glaeda-4
#   failed at 13:06:17.4Z (run 42478799348), both on 2026-11-08.
#
# The home is <runner>/_work/.cargo-home: it persists between this runner's jobs,
# and the hosts' idle-runner eviction skips dot names in _work. The rustup home
# and the toolchains stay shared; the toolchain is on PATH by its own bin dir.
# Ephemeral and single-runner hosts, and a job that sets CARGO_HOME itself to
# anything but $HOME/.cargo, keep their CARGO_HOME.
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

# dtolnay/rust-toolchain writes CARGO_HOME=$HOME/.cargo to GITHUB_ENV: that is
# the shared home, not a home of the job's own, so it does not count.
if [[ -n "${CARGO_HOME:-}" && "${CARGO_HOME%/}" != "${HOME%/}/.cargo" ]]; then
  echo "CARGO_HOME is set by the job ($CARGO_HOME); it is kept"
  exit 0
fi
if [[ "${RUNNER_OS:-}" == "Windows" || -z "${RUNNER_TEMP:-}" || -z "${HOME:-}" ]]; then
  echo "a Windows runner, or RUNNER_TEMP or HOME is unset; the default CARGO_HOME is kept"
  exit 0
fi

# <runner>/_work
if ! work="$(cd "$RUNNER_TEMP/.." 2>/dev/null && pwd -P)"; then
  echo "cannot resolve the work directory of $RUNNER_TEMP; the default CARGO_HOME is kept"
  exit 0
fi
runner_root="$(dirname "$work")"
runners=0
for marker in "$(dirname "$runner_root")"/*/.runner; do
  [[ -f "$marker" ]] && runners=$((runners + 1))
done
# A host whose runner instances are separate users that share one ~/.cargo
# (hetzner-1-3: runner2, runner3, ... all with HOME=/home/runner) has one
# .runner per user's tree, so the count above sees one. The shared home still
# holds another user's files, which this user can neither replace nor delete:
# the R2 registry restore's rm and cargo's crate download both failed with
# "Permission denied (os error 13)" and the aarch64-apple-darwin leg of
# cmux-tui artifacts run 46095639867 failed (job 140826310692, 2026-11-28).
foreign=""
if [[ -d "$HOME/.cargo" ]]; then
  foreign="$(command find "$HOME/.cargo" -maxdepth 3 \( ! -user "$(id -u)" -o ! -writable \) -print -quit 2>/dev/null || true)"
fi
if [[ -z "$foreign" ]] && [[ "$runners" -lt 2 || ! -f "$runner_root/.runner" ]]; then
  echo "this runner does not share its HOME with other runner instances; the default CARGO_HOME is kept"
  exit 0
fi

cargo_home="$work/.cargo-home"
mkdir -p "$cargo_home/bin"
# Keep the host's cargo configuration (read through a link), never its caches.
for name in config.toml config; do
  if [[ -f "$HOME/.cargo/$name" && ! -e "$cargo_home/$name" && ! -L "$cargo_home/$name" ]]; then
    ln -s "$HOME/.cargo/$name" "$cargo_home/$name"
  fi
done
echo "CARGO_HOME=$cargo_home" >> "$GITHUB_ENV"
echo "$cargo_home/bin" >> "$GITHUB_PATH"
if [[ -n "$foreign" ]]; then
  echo "CARGO_HOME=$cargo_home ($HOME/.cargo holds $foreign, which this user cannot write)"
else
  echo "CARGO_HOME=$cargo_home ($runners runner instances share $HOME)"
fi
