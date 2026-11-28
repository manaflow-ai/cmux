#!/usr/bin/env bash
# Puts back the checked-in Cargo.lock that a killed build-xcframework.sh left patched.
#
# build-xcframework.sh builds the iOS slices with nix patched by path, which rewrites
# Cargo.lock; it saves the lock to target/ios-patches/Cargo.lock.orig first and puts it
# back when it ends. A run killed mid-build (a CI step timeout reaps bash and cargo
# without running its trap) leaves the patched lock in the checkout, and the next
# `cargo ... --locked` there fails with "cannot update the lock file". Every entry point
# that runs cargo --locked on this workspace calls this first.
#
# The saved lock is put back only when it is the lock this checkout commits: target/
# outlives a reused CI workspace, so a saved lock from an older checkout is dropped, and
# a lock with uncommitted edits is never overwritten.
set -euo pipefail

rust_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
saved="$rust_dir/target/ios-patches/Cargo.lock.orig"
lock="$rust_dir/Cargo.lock"
[[ -f "$saved" ]] || exit 0
if cmp -s "$saved" "$lock"; then
  rm -f "$saved"
  exit 0
fi
if git -C "$rust_dir" rev-parse -q --verify HEAD >/dev/null 2>&1 &&
  ! git -C "$rust_dir" show HEAD:./Cargo.lock | cmp -s - "$saved"; then
  echo "restore-ios-patch-lock: dropped $saved: it is not this checkout's committed Cargo.lock" >&2
  rm -f "$saved"
  exit 0
fi
cp "$saved" "$lock"
rm -f "$saved"
echo "restore-ios-patch-lock: put back Cargo.lock that a killed iOS build left patched (nix by path)" >&2
