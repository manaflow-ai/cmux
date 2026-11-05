//! The acpmux build id: `<git short hash>[+dirty.<diff fingerprint>] <UTC
//! date>` (build.rs). Peers compare it to tell whether they run the same code.
//!
//! It lives in this leaf crate, not in acpmux, because the build script reruns
//! on every new stamp and every commit, and Cargo recompiles every target of a
//! package whose build script reruns. acpmux depends on this crate only with
//! its default `build-id` feature (the standalone `acpmux` binary and its
//! tests). The cmux-tui binary turns that feature off, depends on this crate
//! itself, and installs the value at start (`acpmux::hub::install_build`), so a new
//! stamp recompiles only this crate and cmux-tui.

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

/// This build's acpmux build id, the part of [`STAMP`] in parentheses. See
/// the crate documentation.
pub fn build() -> &'static str {
    // Read through black_box so the optimizer cannot fold the slice into a
    // constant of its own and drop the whole string.
    let stamp: &'static str = std::hint::black_box(STAMP);
    stamp.split_once(" (").and_then(|(_, rest)| rest.strip_suffix(')')).unwrap_or(stamp)
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_stamp_is_the_version_and_the_build_id_in_one_string() {
        let line = format!("{} ({})", env!("CARGO_PKG_VERSION"), super::build());
        assert_eq!(super::STAMP, format!("acpmux {line}"));
        assert_eq!(super::build(), env!("ACPMUX_BUILD"));
    }
}
