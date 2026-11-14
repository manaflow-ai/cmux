use super::*;

fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
    move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
}

/// Review 2 of #39020 (B1): in cmux the daemon is `<cmux> acp daemon run`, and its executable
/// is cmux, whose own `send` is no acpmux verb. `ACPMUX_BIN` is one path that runs acpmux's
/// CLI: the `acpmux` alias beside it when that is the same file (cmux-tui runs acpmux when
/// argv0 is `acpmux`), else a wrapper script that runs the executable with its prefix. A
/// standalone acpmux replaced by an update names its installed path (N4).
#[test]
fn w5s_acpmux_bin_is_one_path_that_runs_acpmux_under_a_host_prefix() {
    use std::path::{Path, PathBuf};
    let acp = [std::ffi::OsString::from("acp")];
    let none = |_: &Path| false;
    let standalone = bin_choice(Path::new("/opt/x/acpmux (deleted)"), &[], none);
    assert_eq!(standalone, Some(BinChoice::Exe(PathBuf::from("/opt/x/acpmux"))));
    let alias = |p: &Path| p == Path::new("/app/bin/acpmux");
    let aliased = bin_choice(Path::new("/app/bin/cmux"), &acp, alias);
    assert_eq!(aliased, Some(BinChoice::Alias(PathBuf::from("/app/bin/acpmux"))));
    let wrapped = bin_choice(Path::new("/A B/it's/cmux"), &acp, none);
    let script = "#!/bin/sh\nexec '/A B/it'\\''s/cmux' 'acp' \"$@\"\n";
    assert_eq!(wrapped, Some(BinChoice::Wrapper(script.to_owned())));
    assert_eq!(bin_choice(Path::new("cmux"), &acp, none), None, "never a relative path");
}

/// The wrapper script is written once, owner-only and executable, atomically; it is written
/// again only when its text changes (another executable).
#[cfg(unix)]
#[test]
fn w5s_the_wrapper_is_written_owner_only_and_only_when_it_changes() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let home = std::env::temp_dir().join(format!("w5s-wrapper-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let path = wrapper_path(&home);
    install_wrapper(&path, "#!/bin/sh\nexec '/a/cmux' 'acp' \"$@\"\n").unwrap();
    let meta = std::fs::symlink_metadata(&path).ok();
    assert!(meta.as_ref().is_some_and(|m| m.is_file()), "no wrapper at {}", path.display());
    let meta = meta.unwrap();
    assert_eq!(meta.permissions().mode() & 0o777, 0o700, "owner-only and executable");
    install_wrapper(&path, "#!/bin/sh\nexec '/a/cmux' 'acp' \"$@\"\n").unwrap();
    let again = std::fs::symlink_metadata(&path).unwrap();
    assert_eq!(again.ino(), meta.ino(), "the same text is not written again");
    install_wrapper(&path, "#!/bin/sh\nexec '/b/cmux' 'acp' \"$@\"\n").unwrap();
    assert!(std::fs::read_to_string(&path).unwrap().contains("/b/cmux"));
    let _ = std::fs::remove_dir_all(&home);
}

/// F1 of #39020: the wrapper's folder is private state. A `bin` folder another user can
/// write (group or world writable) could swap the script every agent runs: it is refused,
/// and no wrapper is written there.
#[cfg(unix)]
#[test]
fn w5s_a_wrapper_folder_others_can_write_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let home = std::env::temp_dir().join(format!("w5s-wrapper-open-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let path = wrapper_path(&home);
    let bin = path.parent().unwrap();
    std::fs::create_dir_all(bin).unwrap();
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::set_permissions(bin, std::fs::Permissions::from_mode(0o777)).unwrap();
    let written = install_wrapper(&path, "#!/bin/sh\nexec '/a/cmux' 'acp' \"$@\"\n");
    assert!(written.is_err(), "a wrapper was written in a world-writable folder");
    assert!(!path.exists(), "a wrapper was left in a world-writable folder");
    let _ = std::fs::remove_dir_all(&home);
}

/// Review of #39613: a wrapper already in place (an older build wrote it, or the folder was
/// opened later) does not skip the folder check: a `bin` folder another user can write is
/// refused even when the script there holds the same text.
#[cfg(unix)]
#[test]
fn w5s_an_existing_wrapper_in_a_folder_others_can_write_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let home = std::env::temp_dir().join(format!("w5s-wrapper-reopen-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let path = wrapper_path(&home);
    let script = "#!/bin/sh\nexec '/a/cmux' 'acp' \"$@\"\n";
    install_wrapper(&path, script).unwrap();
    let bin = path.parent().unwrap();
    std::fs::set_permissions(bin, std::fs::Permissions::from_mode(0o777)).unwrap();
    let again = install_wrapper(&path, script);
    std::fs::set_permissions(bin, std::fs::Permissions::from_mode(0o700)).unwrap();
    let _ = std::fs::remove_dir_all(&home);
    assert!(again.is_err(), "the same wrapper was accepted in a world-writable folder");
}

/// Review of #39613: a new daemon may get the pid of a dead writer whose temporary file is
/// still there (`.acpmux.<pid>.<n>.tmp`, the pid now its own, so it is not removed as dead):
/// its write still succeeds.
#[cfg(unix)]
#[test]
fn w5s_a_leftover_temporary_with_this_processs_pid_does_not_block_the_write() {
    let home = std::env::temp_dir().join(format!("w5s-wrapper-reuse-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let path = wrapper_path(&home);
    install_wrapper(&path, "#!/bin/sh\nexec '/a/cmux' 'acp' \"$@\"\n").unwrap();
    let bin = path.parent().unwrap();
    // A dead writer had this process's pid: every name this process's next writes could
    // take (the tests of this binary write a few wrappers between them).
    for n in 0..256 {
        let name = format!(".{CLI_ALIAS}.{}.{n}.tmp", std::process::id());
        std::fs::write(bin.join(name), "half").unwrap();
    }
    let written = install_wrapper(&path, "#!/bin/sh\nexec '/b/cmux' 'acp' \"$@\"\n");
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&home);
    assert!(written.is_ok(), "a leftover temporary file blocked the write: {written:?}");
    assert!(text.contains("/b/cmux"), "the wrapper was not written: {text}");
}

/// F2 of #39020: `ACPMUX_BIN` is run from an agent's own working folder, so the wrapper's
/// path is absolute even when the acpmux home is named relative to the daemon's.
#[test]
fn w5s_the_wrapper_path_is_absolute_under_a_relative_home() {
    let path = wrapper_path(std::path::Path::new("rel/acpmux-home"));
    assert!(path.is_absolute(), "{}", path.display());
    assert!(path.ends_with("rel/acpmux-home/bin/acpmux"), "{}", path.display());
}

/// F5 of #39020: a temporary file a writer left when it died (its process is gone) is
/// removed on the next write; one of a live process stays.
#[cfg(unix)]
#[test]
fn w5s_a_dead_writers_temporary_wrapper_is_removed_on_write() {
    let home = std::env::temp_dir().join(format!("w5s-wrapper-tmp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let path = wrapper_path(&home);
    install_wrapper(&path, "#!/bin/sh\nexec '/a/cmux' 'acp' \"$@\"\n").unwrap();
    let bin = path.parent().unwrap();
    // No process has this pid (above every pid limit), so its writer is gone.
    let dead = bin.join(format!(".{CLI_ALIAS}.2147483646.0.tmp"));
    std::fs::write(&dead, "half").unwrap();
    let live = bin.join(format!(".{CLI_ALIAS}.{}.99.tmp", std::process::id()));
    std::fs::write(&live, "half").unwrap();
    install_wrapper(&path, "#!/bin/sh\nexec '/b/cmux' 'acp' \"$@\"\n").unwrap();
    assert!(!dead.exists(), "the dead writer's temporary file stayed");
    assert!(live.exists(), "a live writer's temporary file was removed");
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn this_cli_declares_terminal_outside_a_session_and_agent_inside_one() {
    let mut mux = Map::new();
    declare(&mut mux, env(&[]));
    let hello = json!({"clientInfo": {"name": CLI_NAME}, "_meta": {"acpmux": mux}});
    assert_eq!(of_initialize(&hello), Some(Declared::Terminal));
    // A session id alone (no token for this daemon) is still an agent's shell.
    let mut mux = Map::new();
    declare(&mut mux, env(&[("ACPMUX_SESSION_ID", "s1")]));
    let hello = json!({"clientInfo": {"name": CLI_NAME}, "_meta": {"acpmux": mux}});
    assert_eq!(of_initialize(&hello), Some(Declared::Agent));
}

/// Review F1 (#39320): the CLI a guest MCP server runs (`acpmux_mcp_guest.rs` `new`) says
/// it is a guest, so the daemon never takes its prompt for the owner's terminal send.
#[test]
fn a_guest_cli_declares_no_terminal() {
    let mut mux = Map::new();
    declare(&mut mux, env(&[(crate::desktop_link::GUEST_ENV, "claude-desktop")]));
    assert_eq!(mux.get(KIND_FIELD), Some(&json!(KIND_GUEST)));
    let hello = json!({"clientInfo": {"name": CLI_NAME}, "_meta": {"acpmux": mux}});
    let declared = of_initialize(&hello).unwrap();
    assert_eq!(declared, Declared::Agent);
    assert!(!declared.may_be_owner_terminal());
    // A blank value is no guest.
    let mut mux = Map::new();
    declare(&mut mux, env(&[(crate::desktop_link::GUEST_ENV, " ")]));
    assert_eq!(mux.get(KIND_FIELD), Some(&json!(KIND_TERMINAL)));
}

#[test]
fn an_old_cli_is_named_and_a_foreign_client_declares_nothing() {
    let old = json!({"clientInfo": {"name": CLI_NAME, "version": "0.1.0"}});
    let declared = of_initialize(&old).unwrap();
    assert_eq!(declared.old_client(), Some("acpmux-cli 0.1.0"));
    assert!(!declared.may_be_owner_terminal());
    assert_eq!(of_initialize(&json!({"clientInfo": {"name": "my-script"}})), None);
    assert_eq!(of_initialize(&json!({"protocolVersion": 1})), None);
    // An unknown kind fails closed.
    let odd = json!({"_meta": {"acpmux": {"callerProtocol": 1, "callerKind": "robot"}}});
    assert_eq!(of_initialize(&odd), Some(Declared::Agent));
}

#[test]
fn the_old_cli_refusal_names_the_client_and_the_fix_in_english_and_japanese() {
    let e = old_cli_refused("acpmux-cli 0.1.0", "changing a session's turn cap");
    assert!(e.message.contains("acpmux-cli 0.1.0 is older than this acpmux daemon"), "{e:?}");
    assert!(e.message.contains("\"$ACPMUX_BIN\" send"), "{e:?}");
    assert!(e.message.contains("より古く"), "{e:?}");
    assert_eq!(e.data.unwrap()["reason"], OLD_CLI_REASON);
}
