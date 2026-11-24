//! The acpmux build id: `<git short hash>[+dirty.<diff fingerprint>] <UTC
//! date>` (build.rs). Peers compare it to tell whether they run the same code.
//!
//! It lives in this leaf crate, not in acpmux, because the build script reruns
//! on every new stamp and every commit, and Cargo recompiles every target of a
//! package whose build script reruns. acpmux depends on this crate only with
//! its default `build-id` feature (the acpmux package's own `acpmux` binary and
//! its tests). The cmux-tui binary and the shipped standalone acpmux
//! (acpmux-standalone) turn that feature off, depend on this crate themselves,
//! and install the value at start (`acpmux::hub::install_build`), so a new
//! stamp recompiles only this crate and those binaries.

#![forbid(unsafe_code)]

/// This build's stamp as one string: `acpmux <version> (<build id>)`.
///
/// It must sit in the binary as one contiguous string: an acpmux that pushes
/// an update reads the build id out of the new binary's bytes (the first
/// `<version> (<build id>)`, `cli/host_update.rs`) without running it, and
/// an older updater has no other way to find it. With only the bare build id
/// in the binary that scan took rustc's `rustc version 1.95.0 (<hash> <date>)`
/// instead and refused every update as a push mismatch. [`build`] reads its
/// part of this at run time, so the whole string stays in the binary.
pub static STAMP: &str =
    concat!("acpmux ", env!("CARGO_PKG_VERSION"), " (", env!("ACPMUX_BUILD"), ")");

/// This build's commit time as one string: `acpmux-commit-time=<Unix
/// seconds>;` (0 when the build could not tell). A host's install script
/// reads it out of the installed and the pushed binary with `grep` and
/// refuses to replace a newer commit's binary with an older one (acpmux
/// `cli/hosts.rs`), so it must sit in the binary as one string: [`build`],
/// which every binary calls at start, reads it, which keeps it there.
pub static COMMIT_STAMP: &str = concat!("acpmux-commit-time=", env!("ACPMUX_COMMIT_TIME"), ";");

/// This build's commit time in Unix seconds, from [`COMMIT_STAMP`]; 0 when unknown.
pub fn commit_time() -> u64 {
    let stamp: &'static str = std::hint::black_box(COMMIT_STAMP);
    stamp
        .strip_prefix("acpmux-commit-time=")
        .and_then(|rest| rest.strip_suffix(';'))
        .and_then(|secs| secs.parse().ok())
        .unwrap_or(0)
}

/// This build's acpmux build id, the part of [`STAMP`] in parentheses. See
/// the crate documentation.
pub fn build() -> &'static str {
    // Read through black_box so the optimizer cannot fold the slice into a
    // constant of its own and drop the whole string.
    let stamp: &'static str = std::hint::black_box(STAMP);
    // Every binary calls this at start, so COMMIT_STAMP stays in it too.
    std::hint::black_box(COMMIT_STAMP);
    stamp.split_once(" (").and_then(|(_, rest)| rest.strip_suffix(')')).unwrap_or(stamp)
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
