//! The shipped acpmux binary reports the same build id as before: the acpmux
//! lib is built here without its `build-id` feature, so the id comes only from
//! `install_build` in this binary's `main`.

use std::process::Command;

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_acpmux-standalone")
}

/// `acpmux --version` shows `<version> (<build id>)`, the stamped id and not
/// the unstamped default.
#[test]
fn version_shows_the_stamped_build_id() {
    let out = Command::new(binary()).arg("--version").output().unwrap();
    assert!(out.status.success(), "--version failed: {out:?}");
    let stdout = String::from_utf8(out.stdout).unwrap();
    let build = acpmux_build_id::build();
    assert_ne!(build, "unstamped");
    assert_eq!(stdout.trim(), format!("acpmux {} ({build})", acpmux::hub::VERSION));
}

/// The build id starts with this commit's short hash, as acpmux-build-id's
/// build script stamps it (from git, or CMUX_GIT_SHORT_SHA without git).
#[test]
fn the_build_id_names_this_commit() {
    let head = Command::new("git")
        .args(["rev-parse", "--short=9", "HEAD"])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned());
    let Some(head) = head else { return };
    let build = acpmux_build_id::build();
    assert!(build.starts_with(&head), "build id {build:?} is not for commit {head}");
}

/// acpmux updaters read `<version> (<build id>)` out of the new binary's bytes
/// without running it (acpmux `tests/binary_build_stamp.rs`), so the shipped
/// binary carries acpmux-build-id's `STAMP` as one string.
#[test]
fn the_binary_holds_the_stamp_as_one_string() {
    let bytes = std::fs::read(binary()).unwrap();
    let line = format!("{} ({})", acpmux::hub::VERSION, acpmux_build_id::build());
    assert!(
        bytes.windows(line.len()).any(|w| w == line.as_bytes()),
        "the acpmux-standalone binary does not contain `{line}` as one string"
    );
}
