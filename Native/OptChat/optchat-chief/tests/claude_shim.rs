//! A background agent a Chief session starts with `claude` (no terminal)
//! runs the user's own Claude CLI with the user's own config, never the
//! session harness's: a subrouter session plants `CLAUDE_CONFIG_DIR` (an
//! account home whose settings name `http://127.0.0.1:1`) and its route in
//! its process env, and a `claude -p` that inherited them retried a dead
//! base URL until it timed out (a103, 2026-10-19).

use std::os::unix::fs::PermissionsExt;
use std::process::Command;

use optchat_chief::prompt::Tools;
use optchat_chief::session_dir::{SessionSetup, write};

const POISON: [(&str, &str); 4] = [
    ("CLAUDE_CONFIG_DIR", "/x/.codex-accounts/claude/_p1"),
    ("ANTHROPIC_BASE_URL", "http://127.0.0.1:1"),
    ("ANTHROPIC_AUTH_TOKEN", "sr2-session-token"),
    ("CLAUDECODE", "1"),
];

/// The Chief's session dir with a fake "real" claude after its bin on PATH
/// that prints its argv and the variables it got.
fn session() -> (tempfile::TempDir, std::path::PathBuf, String) {
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    paths.create().unwrap();
    let setup = SessionSetup {
        exe: "/x/optchat-chief".into(),
        env: Default::default(),
        instructions: None,
        tools: Tools::Cli(paths.bin.join("chief").display().to_string()),
        user_env: Default::default(),
        profile_tool: false,
        chiefs_tool: false,
    };
    write(&paths, &setup).unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    let fake = real.join("claude");
    std::fs::write(
        &fake,
        "#!/bin/sh\necho \"argv=$*\"\nfor v in CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN CLAUDECODE KEEP_ME; do eval \"echo $v=\\${$v-unset}\"; done\n",
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:{}:/usr/bin:/bin", paths.bin.display(), real.display());
    (dir, paths.bin.join("claude"), path)
}

/// Runs `command`. A parallel test that forks while this one's script is
/// still open for write makes Linux refuse the exec (ETXTBSY) for a moment.
fn output(command: &mut Command) -> std::process::Output {
    for _ in 0..50 {
        match command.output() {
            Err(e) if e.kind() == std::io::ErrorKind::ExecutableFileBusy => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            result => return result.unwrap(),
        }
    }
    command.output().unwrap()
}

#[test]
fn a_claude_started_from_a_chief_session_gets_the_users_own_config() {
    let (_dir, shim, path) = session();
    assert!(shim.exists(), "the session bin has no claude shim");
    let mut command = Command::new(&shim);
    command
        .args(["-p", "reply with: hi"])
        .env_clear()
        .env("PATH", &path)
        .env("HOME", "/x/home")
        .env("KEEP_ME", "kept")
        .envs(POISON);
    let out = output(&mut command);
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{text} {}",
        String::from_utf8_lossy(&out.stderr)
    );
    // The user's real claude ran, with the arguments as given.
    assert!(text.contains("argv=-p reply with: hi"), "{text}");
    // None of the harness's planted variables reached it, so Claude Code
    // reads ~/.claude/settings.json and the user's login.
    for (key, _) in POISON {
        assert!(
            text.contains(&format!("{key}=unset")),
            "{key} leaked: {text}"
        );
    }
    // Everything else passes through.
    assert!(text.contains("KEEP_ME=kept"), "{text}");
}

#[test]
fn chief_keep_claude_env_keeps_the_inherited_config() {
    let (_dir, shim, path) = session();
    let mut command = Command::new(&shim);
    command
        .env_clear()
        .env("PATH", &path)
        .env("CHIEF_KEEP_CLAUDE_ENV", "1")
        .envs(POISON);
    let out = output(&mut command);
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        text.contains("CLAUDE_CONFIG_DIR=/x/.codex-accounts/claude/_p1"),
        "{text}"
    );
}
