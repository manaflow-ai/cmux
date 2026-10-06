//! Every `cmux` call of a Chief turn reaches the app's own daemon (hmchief7:
//! the Chief's `cmux workspace create` landed in the user's release app,
//! session `cmux-app`, because the turn env named the tagged control socket
//! but no daemon socket, and the CLI guessed the untagged app).
//!
//! - The turn env names the host's `--daemon-socket` in CMUX_TUI_SOCKET and
//!   CMUX_MUX_SOCKET, the keys the `cmux` CLI reads before any guess.
//! - The CLI bundled next to the host leads PATH, ahead of every other `cmux`
//!   (~/bin, ~/.local/bin, Homebrew), once.
//! - Claude Code's project settings and the `chief` launcher carry the same.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use optchat_chief::host::session_env;

fn bundle() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("chief-routing-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("cmux"), b"#!/bin/sh\n").unwrap();
    std::fs::write(dir.join("optchat-chief"), b"").unwrap();
    dir
}

fn inherited(key: &str) -> Option<String> {
    let map: BTreeMap<&str, &str> = [
        (
            "PATH",
            "/Users/u/bin:/Users/u/.local/bin:/opt/homebrew/bin:/usr/bin:/bin",
        ),
        ("CMUX_SOCKET_PATH", "/tmp/cmux-debug-hmchief7.sock"),
    ]
    .into_iter()
    .collect();
    map.get(key).map(|v| (*v).to_owned())
}

const DAEMON: &str = "/var/folders/x/T/cmux-tui-501/cmux-app-hmchief7.sock";

#[test]
fn the_turn_env_names_the_apps_daemon_socket() {
    let bin = bundle();
    let env = session_env(
        Path::new("/h"),
        DAEMON,
        Path::new("/a/acpmux.sock"),
        &bin.join("optchat-chief"),
        &inherited,
    );
    assert_eq!(env.get("CMUX_TUI_SOCKET").map(String::as_str), Some(DAEMON));
    assert_eq!(env.get("CMUX_MUX_SOCKET").map(String::as_str), Some(DAEMON));
    assert_eq!(
        env.get("CMUX_SOCKET_PATH").map(String::as_str),
        Some("/tmp/cmux-debug-hmchief7.sock")
    );
}

#[test]
fn the_bundled_cli_leads_path_once() {
    let bin = bundle();
    let env = session_env(
        Path::new("/h"),
        DAEMON,
        Path::new("/a/acpmux.sock"),
        &bin.join("optchat-chief"),
        &|key: &str| {
            if key == "PATH" {
                Some(format!("/Users/u/bin:{}:/usr/bin", bin.display()))
            } else {
                inherited(key)
            }
        },
    );
    let path = env["PATH"].clone();
    let dirs: Vec<&str> = path.split(':').collect();
    assert_eq!(dirs[0], bin.display().to_string(), "PATH {path}");
    assert_eq!(
        dirs.iter()
            .filter(|d| **d == bin.display().to_string())
            .count(),
        1,
        "PATH {path}"
    );
    assert!(dirs.contains(&"/Users/u/bin"), "PATH {path}");
}

#[test]
fn claude_settings_and_the_launcher_carry_the_pinned_socket() {
    use optchat_chief::paths::Paths;
    use optchat_chief::prompt::Tools;
    use optchat_chief::session_dir::{SessionSetup, launcher, settings_json};
    let bin = bundle();
    let env = session_env(
        Path::new("/h"),
        DAEMON,
        Path::new("/a/acpmux.sock"),
        &bin.join("optchat-chief"),
        &inherited,
    );
    let setup = SessionSetup {
        exe: bin.join("optchat-chief").display().to_string(),
        cmux_mcp: None,
        env,
        instructions: None,
        tools: Tools::Mcp,
    };
    let paths = Paths::new(Path::new("/h"));
    let settings = settings_json(&setup, &paths);
    assert_eq!(settings["env"]["CMUX_TUI_SOCKET"], DAEMON);
    let path = settings["env"]["PATH"].as_str().unwrap().to_owned();
    // The launcher directory first (the `chief` command), then the bundled CLI.
    let dirs: Vec<&str> = path.split(':').collect();
    assert_eq!(dirs[0], paths.bin.display().to_string());
    assert_eq!(dirs[1], bin.display().to_string(), "PATH {path}");
    let script = launcher(&setup);
    assert!(
        script.contains(&format!(
            "CMUX_TUI_SOCKET={DAEMON}; export CMUX_TUI_SOCKET\n"
        )),
        "{script}"
    );
}

/// A brain host shared by builds (one Chief home per account) gets the
/// active app's daemon through CMUX_APP_DAEMON_SOCKET (a constant link the
/// app republishes); its `--daemon-socket` is then the Chief's own
/// conversation owner, which holds no workspaces.
#[test]
fn cmux_app_daemon_socket_wins_over_the_daemon_socket() {
    let bin = bundle();
    let link = "/Users/u/.cmux/chief/acct/state/app-daemon.sock";
    let env = session_env(
        Path::new("/h"),
        "/T/cmux-chief-owner.sock",
        Path::new("/a/acpmux.sock"),
        &bin.join("optchat-chief"),
        &|key: &str| {
            if key == "CMUX_APP_DAEMON_SOCKET" {
                Some(link.to_owned())
            } else {
                inherited(key)
            }
        },
    );
    assert_eq!(env.get("CMUX_TUI_SOCKET").map(String::as_str), Some(link));
    assert_eq!(env.get("CMUX_MUX_SOCKET").map(String::as_str), Some(link));
    assert_eq!(
        env.get("CMUX_DAEMON_SOCKET").map(String::as_str),
        Some("/T/cmux-chief-owner.sock")
    );
}

#[test]
fn a_childs_preset_is_per_home_and_harness() {
    use optchat_chief::agents::child_preset_name;
    assert_eq!(
        child_preset_name("1a2b3c4d", "claude-sr").as_deref(),
        Some("chief-child-1a2b3c4d-claude-sr")
    );
    assert_eq!(child_preset_name("1a2b3c4d", "a b"), None);
    assert_eq!(child_preset_name("1a2b3c4d", ""), None);
}
