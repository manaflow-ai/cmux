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

/// This build's acpmux build id. See the crate documentation.
pub const BUILD: &str = env!("ACPMUX_BUILD");
