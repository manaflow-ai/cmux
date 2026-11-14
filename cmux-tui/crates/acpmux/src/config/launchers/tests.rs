use super::which_in;
use std::os::unix::fs::PermissionsExt as _;

/// A `claude` the shell could not run (no execute bit) earlier on PATH does not hide the one it
/// would run.
#[test]
fn which_skips_a_file_it_could_not_run() {
    let first = tempfile::tempdir().unwrap();
    let second = tempfile::tempdir().unwrap();
    std::fs::write(first.path().join("claude"), "").unwrap();
    let runnable = second.path().join("claude");
    std::fs::write(&runnable, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&runnable, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::join_paths([first.path(), second.path()]).unwrap();
    assert_eq!(which_in(&path, "claude"), Some(runnable.to_string_lossy().into_owned()));
    assert_eq!(which_in(&path, "codex"), None);
}
