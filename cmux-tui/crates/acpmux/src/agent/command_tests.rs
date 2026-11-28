/// A remote-origin harness and its host start from [`super::host_environment`]: the `cmux`
/// CLI it runs keeps this daemon's build space, so a dev build's agent never reaches
/// nightly's Cloud data.
#[test]
fn a_remote_harness_keeps_the_build_space() {
    assert!(super::host_env_allowed("CMUX_BUILD_SPACE"));
    assert!(!super::host_env_allowed("CMUX_SOCKET_PATH"));
}

#[cfg(target_os = "linux")]
#[test]
fn local_subscription_launch_keeps_tokens_out_of_arguments() {
    let codex = crate::config::HarnessProfile {
        kind: crate::config::HarnessKind::Acp,
        argv: vec!["codex".into(), "app-server".into(), "--stdio".into()],
        env: [
            (crate::routes::NAME_KEY.to_owned(), "ChatGPT".into()),
            (crate::agent_credentials::CHATGPT_TOKEN.to_owned(), "fixture-chatgpt-token".into()),
            (crate::routes::UNSET_KEY.to_owned(), "OPENAI_API_KEY,OPENAI_BASE_URL".into()),
        ]
        .into_iter()
        .collect(),
        description: None,
        fallback: None,
        family: Some("codex".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let command = harness_command("codex", &codex, &std::env::temp_dir(), None, None).unwrap();
    let args: Vec<_> = command.as_std().get_args().map(|arg| arg.to_string_lossy()).collect();
    assert_eq!(args[0], "app-server");
    assert!(args.iter().any(|arg| arg.contains("backend-api/codex")));
    assert!(args.iter().all(|arg| !arg.contains("fixture-chatgpt-token")));
    let env: std::collections::BTreeMap<_, _> =
        explicit_env(command.as_std()).into_iter().collect();
    assert_eq!(
        env[crate::agent_credentials::CHATGPT_TOKEN].as_deref(),
        Some("fixture-chatgpt-token")
    );
    assert!(env["OPENAI_API_KEY"].is_none());

    let claude = crate::config::HarnessProfile {
        argv: vec!["claude".into()],
        env: [(crate::agent_credentials::CLAUDE_OAUTH.to_owned(), "fixture-claude-token".into())]
            .into_iter()
            .collect(),
        family: Some("claude".into()),
        ..codex
    };
    let command = harness_command("claude", &claude, &std::env::temp_dir(), None, None).unwrap();
    assert!(
        command
            .as_std()
            .get_args()
            .all(|arg| !arg.to_string_lossy().contains("fixture-claude-token"))
    );
    let env: std::collections::BTreeMap<_, _> =
        explicit_env(command.as_std()).into_iter().collect();
    assert_eq!(
        env[crate::agent_credentials::CLAUDE_OAUTH].as_deref(),
        Some("fixture-claude-token")
    );
}

#[cfg(target_os = "linux")]
#[test]
fn remote_outer_command_scrubs_loader_env() {
    let p = serde_json::from_value(serde_json::json!({
        "argv": ["/usr/bin/true"], "env": {"ACPMUX_REMOTE_ENV_POLICY": "1",
            "LD_PRELOAD": "injected", "GLIBC_TUNABLES": "injected",
            "TMPDIR": "/injected", "MALLOC_CHECK_": "3"}
    }))
    .unwrap();
    let cmd = harness_command("remote", &p, &std::env::temp_dir(), None, None).unwrap();
    let env = command_env_cleared(&cmd);
    assert!(!env.iter().any(|(k, _)| matches!(
        k.as_str(),
        "LD_PRELOAD" | "GLIBC_TUNABLES" | "TMPDIR" | "MALLOC_CHECK_"
    )));
}

use super::*;

/// `agents.envExclude` (agent_env.rs) removes its names from the agent's whole env, the
/// profile's and the inherited ones, last; acpmux's own session wiring and the marker stay out.
#[test]
fn env_exclude_removes_names_last_but_keeps_acpmux_wiring() {
    let p = serde_json::from_value(serde_json::json!({
        "argv": ["/usr/bin/true"],
        "env": {"SECRET_TOKEN": "x", "SECRET_OTHER": "y", "KEEP": "1", "PATH": "/usr/bin",
            (crate::agent_env::EXCLUDE_MARKER): "SECRET_*,HOME,ACPMUX_*"}
    }))
    .unwrap();
    let cmd = harness_command("t", &p, &std::env::temp_dir(), None, Some(("s1", "n1"))).unwrap();
    let env = command_env(&cmd);
    let has = |k: &str| env.iter().any(|(n, _)| n == k);
    assert!(!has("SECRET_TOKEN") && !has("SECRET_OTHER") && !has("HOME"));
    assert!(has("KEEP"));
    assert!(has("ACPMUX_SESSION_ID") && has("ACPMUX_SOCKET"));
    assert!(!has(crate::agent_env::EXCLUDE_MARKER));
}

/// A daemon started by a bounded command holds its `CMUX_DEADLINE`: an agent it starts
/// must not, or the fleet's orphan reaper ends the agent once the bound passes.
#[test]
fn an_agent_never_inherits_a_tool_calls_deadline() {
    let profile: HarnessProfile =
        serde_json::from_value(serde_json::json!({ "argv": ["claude"] })).unwrap();
    let cmd = harness_command("local", &profile, &std::env::temp_dir(), None, None).unwrap();
    let removed: Vec<String> = cmd
        .as_std()
        .get_envs()
        .filter(|(_, value)| value.is_none())
        .map(|(key, _)| key.to_string_lossy().into_owned())
        .collect();
    for key in CALL_BOUND_ENV {
        assert!(removed.iter().any(|k| k == key), "{key} must be removed: {removed:?}");
    }
}

/// A Claude session is launched under its acpmux name (`--name`), so Claude
/// Code's peer list says what `acpmux ls` says; with cmux's tools off too.
#[test]
fn the_hook_daemon_token_is_off_unless_its_setting_names_a_file() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("token");
    let tok = "0123456789abcdef".repeat(3);
    std::fs::write(&file, format!("{tok}\n")).unwrap();
    let home = dir.path().to_path_buf();
    let unset = |k: &str| (k == "HOME").then(|| home.clone().into_os_string());
    assert_eq!(super::hook_daemon_token(unset), None, "off by default, whatever is on disk");
    let set = |k: &str| (k == super::HOOK_TOKEN_FILE_ENV).then(|| file.clone().into_os_string());
    assert_eq!(super::hook_daemon_token(set).as_deref(), Some(tok.as_str()));
    std::fs::write(&file, "not hex at all, not a token\n").unwrap();
    assert_eq!(super::hook_daemon_token(set), None, "a stray file never becomes a header");
    std::fs::remove_file(&file).unwrap();
    assert_eq!(super::hook_daemon_token(set), None, "no file, no token");
}

#[test]
fn a_claude_session_is_launched_under_its_acpmux_name() {
    let mut profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["claude"]
    }))
    .unwrap();
    profile.kind = crate::config::HarnessKind::ClaudeStdio;
    profile.env.insert(crate::agent_tools::SWITCH_ENV.into(), "0".into());
    let args = |line: Vec<&str>, name: &str| -> Vec<String> {
        let line = Some(("claude".to_owned(), line.into_iter().map(str::to_owned).collect()));
        let id = "01a15d7d-b692-76b3-b8de-a9a71809de2a";
        let cmd = harness_command("local", &profile, &std::env::temp_dir(), line, Some((id, name)))
            .unwrap();
        cmd.as_std().get_args().map(|a| a.to_string_lossy().into_owned()).collect()
    };
    let named = args(vec!["-p"], "reviewer");
    assert!(named.windows(2).any(|w| w == ["--name", "reviewer"]), "{named:?}");
    // A command line that names the session keeps its own name.
    let own = args(vec!["-p", "--name", "pinned"], "reviewer");
    assert!(!own.iter().any(|a| a == "reviewer"), "{own:?}");
    // No name, no flag; a remote chain (its env policy) gets none either.
    assert!(!args(vec!["-p"], " ").iter().any(|a| a == "--name"));
    // A local profile's own `--strict-mcp-config` is no remote chain: it is named.
    let strict = args(vec!["-p", "--strict-mcp-config"], "reviewer");
    assert!(strict.windows(2).any(|w| w == ["--name", "reviewer"]), "{strict:?}");
    let env =
        std::collections::BTreeMap::from([(REMOTE_ENV_POLICY_KEY.to_owned(), "1".to_owned())]);
    assert!(claude_name_args(&env, &[], "reviewer").is_empty());
}

#[test]
fn hosted_remote_environment_cannot_be_reopened_by_a_profile_key_collision() {
    let mut profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/usr/bin/true"],
        "env": {
            "ACPMUX_REMOTE_ENV_POLICY": "1",
            "__ACPMUX_REMOTE_ENV_CLEARED": "collision"
        }
    }))
    .unwrap();
    profile.kind = crate::config::HarnessKind::Acp;
    let command = harness_command("remote", &profile, &std::env::temp_dir(), None, None).unwrap();
    let env = command_env_cleared(&command);
    assert!(
        !env.iter().any(|(key, _)| key == "CARGO_MANIFEST_DIR"),
        "hosted projection recovered the daemon environment"
    );
}

/// Claude Code is pinned to the preview format the hub records for its
/// launch (`preview_format`); another harness is neither pinned nor HTML.
#[test]
fn claude_code_is_pinned_to_the_preview_format_the_hub_records() {
    use crate::config::HarnessKind;
    use crate::questions::{PREVIEW_FORMAT_ENV, PreviewFormat};
    let profile = |kind, value: &str| {
        let mut p: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": ["/usr/bin/true"]})).unwrap();
        p.kind = kind;
        p.env.insert(PREVIEW_FORMAT_ENV.into(), value.into());
        p
    };
    let pinned = |p: &HarnessProfile| {
        let command = harness_command("local", p, &std::env::temp_dir(), None, None).unwrap();
        let env = command_env(&command);
        env.into_iter().find(|(k, _)| k == PREVIEW_FORMAT_ENV).map(|(_, v)| v)
    };
    let html = profile(HarnessKind::ClaudeStdio, " html ");
    assert_eq!(preview_format(&html), PreviewFormat::Html);
    assert_eq!(pinned(&html).as_deref(), Some("html"));
    let command = |p: &HarnessProfile| {
        pinned_preview_format(
            &harness_command("local", p, &std::env::temp_dir(), None, None).unwrap(),
        )
    };
    assert_eq!(command(&html), PreviewFormat::Html);
    let text = profile(HarnessKind::ClaudeStdio, "markdown");
    assert_eq!(preview_format(&text), PreviewFormat::Monospace);
    assert_eq!(pinned(&text).as_deref(), Some("markdown"));
    assert_eq!(command(&text), PreviewFormat::Monospace);
    // A reference that does not resolve starts no agent, and labels nothing HTML.
    let missing = profile(HarnessKind::ClaudeStdio, "${env:ACPMUX_TEST_NO_SUCH_FORMAT}");
    assert_eq!(preview_format(&missing), PreviewFormat::Monospace);
    assert_eq!(preview_format(&profile(HarnessKind::Acp, "html")), PreviewFormat::Monospace);
}

#[test]
fn hosted_local_environment_keeps_the_daemon_base() {
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/usr/bin/true"]
    }))
    .unwrap();
    let command = harness_command("local", &profile, &std::env::temp_dir(), None, None).unwrap();
    let env = command_env(&command);
    assert!(
        env.iter().any(|(key, _)| key == "CARGO_MANIFEST_DIR"),
        "hosted projection discarded the local daemon environment"
    );
}

/// An agent acpmux starts reads the settings file the app runs on: the app
/// hands `CMUX_NEXT_CONFIG_FILE` to the daemon (CmuxNext
/// `LaunchIdentity.terminalEnvironment`), and a local agent's resolved
/// environment has it, so the agent's `claude` or `codex` and the
/// `cmux mcp serve` it starts read that file. The daemon's environment is
/// this process's, set before it starts: the check runs in a child of this
/// test binary started with the variable
/// ([`a_local_agent_keeps_the_apps_settings_file_child`]).
#[test]
fn a_local_agent_keeps_the_apps_settings_file() {
    let key = crate::user_settings::CONFIG_OVERRIDE;
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "agent::command::tests::a_local_agent_keeps_the_apps_settings_file_child",
        ])
        .args(["--nocapture", "--test-threads", "1"])
        .env(key, "/Users/someone/.config/cmux/cmux-next-cu-fresh.json")
        .env("ACPMUX_TEST_SETTINGS_FILE_CHILD", "1")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success() && stdout.contains("1 passed"),
        "{stdout}{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// [`a_local_agent_keeps_the_apps_settings_file`]'s check, in a process
/// started with the variable; outside one it has nothing to check. The
/// agent is a real process (`/usr/bin/env`) started from the launch acpmux
/// builds, and its own printed environment is read.
#[test]
fn a_local_agent_keeps_the_apps_settings_file_child() {
    if std::env::var_os("ACPMUX_TEST_SETTINGS_FILE_CHILD").is_none() {
        return;
    }
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/usr/bin/env"]
    }))
    .unwrap();
    let mut command =
        harness_command("local", &profile, &std::env::temp_dir(), None, None).unwrap();
    command.stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    let output = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        // Spawned inside the runtime: tokio registers the pipes with its reactor.
        .block_on(async move { command.output().await })
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let key = crate::user_settings::CONFIG_OVERRIDE;
    let printed = String::from_utf8_lossy(&output.stdout);
    let value = printed.lines().find_map(|line| line.strip_prefix(&format!("{key}=")));
    assert_eq!(
        value,
        Some("/Users/someone/.config/cmux/cmux-next-cu-fresh.json"),
        "the agent's environment lacks the app's settings file: {printed}"
    );
}

/// The env `harness_command` gives a session `id` of `profile_env`, with
/// the per-user directory in `base`.
#[cfg(unix)]
fn session_env(
    base: &std::path::Path,
    id: &str,
    profile_env: serde_json::Value,
) -> Vec<(String, String)> {
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/usr/bin/true"],
        "env": profile_env
    }))
    .unwrap();
    let cmd = super::super::session_tmp::with_base(base, || {
        harness_command("local", &profile, &std::env::temp_dir(), None, Some((id, "lane")))
    })
    .unwrap();
    command_env(&cmd)
}

#[cfg(unix)]
fn var(env: &[(String, String)], key: &str) -> Option<String> {
    env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
}

#[cfg(unix)]
#[test]
fn every_local_session_gets_its_own_temporary_folder() {
    use super::super::session_tmp::{SESSION_TMPDIR_ENV, daemon_root};
    let scratch = std::env::temp_dir().join(format!(
        "acpmux-cmd-tmp-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ));
    std::fs::create_dir_all(&scratch).unwrap();
    let base = scratch.join("acpmux-u");
    let (a, b) = ("01a15d7d-b692-76b3-b8de-a9a71809de2a", "01a15db7-20cd-7e10-8535-158031297e5c");
    let root = daemon_root(&base, &crate::config::home());
    let runtime = serde_json::json!({"XDG_RUNTIME_DIR": "/run/user/4242"});
    let env_a = session_env(&base, a, runtime.clone());
    let env_b = session_env(&base, b, runtime);
    let dir_a = root.join(a).display().to_string();
    assert_eq!(var(&env_a, "TMPDIR"), Some(dir_a.clone()));
    assert_eq!(var(&env_a, SESSION_TMPDIR_ENV), Some(dir_a.clone()));
    assert_eq!(var(&env_b, "TMPDIR"), Some(root.join(b).display().to_string()));
    assert!(root.join(a).is_dir() && root.join(b).is_dir());
    // A profile TMPDIR still wins; the session folder is still named.
    let env =
        session_env(&base, a, serde_json::json!({"TMPDIR": "/p/tmp", "XDG_RUNTIME_DIR": "/r"}));
    assert_eq!(var(&env, "TMPDIR").as_deref(), Some("/p/tmp"));
    assert_eq!(var(&env, SESSION_TMPDIR_ENV), Some(dir_a.clone()));
    // Without a runtime dir (when this test process has none): a Mac gives
    // the session its folder as TMPDIR and pins the socket base the agent
    // resolved before (the TMPDIR it has without a session); Linux gives it
    // its folder and the user's systemd runtime dir when there is one, else
    // TMPDIR stays and Claude Code's own folder is the session's.
    if std::env::var_os("XDG_RUNTIME_DIR").is_none_or(|v| v.is_empty()) {
        // SAFETY: getuid has no preconditions.
        let runtime = super::super::session_tmp::user_runtime_dir(unsafe { libc::getuid() });
        let plain: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": ["/usr/bin/true"]})).unwrap();
        let unsessioned =
            harness_command("local", &plain, &std::env::temp_dir(), None, None).unwrap();
        let before = var(&command_env(&unsessioned), "TMPDIR").filter(|v| !v.is_empty());
        let env = session_env(&base, a, serde_json::json!({}));
        assert_eq!(var(&env, SESSION_TMPDIR_ENV), Some(dir_a.clone()));
        match (before.filter(|_| cfg!(target_os = "macos")), &runtime) {
            (Some(before), _) => {
                assert_eq!(var(&env, "TMPDIR"), Some(dir_a.clone()));
                assert_eq!(var(&env, "XDG_RUNTIME_DIR"), Some(before));
            }
            (None, Some(runtime)) => {
                assert_eq!(var(&env, "TMPDIR"), Some(dir_a.clone()));
                assert_eq!(var(&env, "XDG_RUNTIME_DIR"), Some(runtime.display().to_string()));
            }
            (None, None) => {
                assert_eq!(
                    var(&env, "TMPDIR").filter(|v| !v.is_empty()),
                    var(&command_env(&unsessioned), "TMPDIR").filter(|v| !v.is_empty())
                );
                if !cfg!(target_os = "macos") {
                    assert_eq!(var(&env, "CLAUDE_CODE_TMPDIR"), Some(dir_a.clone()));
                }
            }
        }
        // A profile's TMPDIR still wins there too; the pinned base is that TMPDIR, the
        // base the agent resolves its sockets under.
        let env = session_env(&base, a, serde_json::json!({"TMPDIR": "/var/folders/x/T/"}));
        assert_eq!(var(&env, SESSION_TMPDIR_ENV), Some(dir_a.clone()));
        assert_eq!(var(&env, "TMPDIR").as_deref(), Some("/var/folders/x/T/"));
        if cfg!(target_os = "macos") {
            assert_eq!(var(&env, "XDG_RUNTIME_DIR").as_deref(), Some("/var/folders/x/T/"));
        }
    }
    // A profile that blanks XDG_RUNTIME_DIR: no pin can hold, TMPDIR stays.
    let env = session_env(&base, a, serde_json::json!({"XDG_RUNTIME_DIR": "", "TMPDIR": "/q"}));
    assert_eq!(var(&env, "TMPDIR").as_deref(), Some("/q"));
    assert_eq!(var(&env, SESSION_TMPDIR_ENV), Some(dir_a));
    let _ = std::fs::remove_dir_all(&scratch);
}

#[cfg(unix)]
#[test]
fn a_remote_session_keeps_its_environment() {
    let scratch = std::env::temp_dir().join(format!(
        "acpmux-cmd-remote-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ));
    let base = scratch.join("acpmux-u");
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/usr/bin/true"],
        "env": {"ACPMUX_REMOTE_ENV_POLICY": "1", "XDG_RUNTIME_DIR": "/run/user/4242"}
    }))
    .unwrap();
    let id = "01a15d7d-b692-76b3-b8de-a9a71809de2a";
    let cmd = super::super::session_tmp::with_base(&base, || {
        harness_command("remote", &profile, &std::env::temp_dir(), None, Some((id, "r")))
    })
    .unwrap();
    let env = command_env_cleared(&cmd);
    assert_eq!(var(&env, super::super::session_tmp::SESSION_TMPDIR_ENV), None);
    assert!(!var(&env, "TMPDIR").is_some_and(|t| t.starts_with(&*base.to_string_lossy())));
    assert!(!base.exists(), "a remote session made a local temporary folder");
    let _ = std::fs::remove_dir_all(&scratch);
}

/// A profile or preset PATH goes first but never hides the login PATH: the Chief's
/// built-in subagent preset was saved with the daemon's bare launchd PATH
/// (`<bundle>/bin:/usr/bin:/bin:/usr/sbin:/sbin`) before the login import ran, and every
/// `claude` spawn then failed `spawn harness process: No such file or directory`.
#[cfg(unix)]
#[test]
fn a_profile_path_keeps_the_login_path_after_it() {
    let scratch = std::env::temp_dir().join(format!(
        "acpmux-cmd-path-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ));
    let base = scratch.join("acpmux-u");
    let bare = "/acpmux-test-bundle/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    let login = crate::login_env::agent_path().expect("the test process has a PATH");
    let login: Vec<String> =
        std::env::split_paths(&login).map(|p| p.to_string_lossy().into_owned()).collect();
    let extra: Vec<&String> =
        login.iter().filter(|d| !d.is_empty() && !bare.split(':').any(|b| b == *d)).collect();
    assert!(!extra.is_empty(), "the login PATH must list a directory the bare PATH lacks");
    let env = session_env(
        &base,
        "01a15d7d-b692-76b3-b8de-a9a71809de2a",
        serde_json::json!({"PATH": bare}),
    );
    let path = var(&env, "PATH").expect("a PATH");
    let entries: Vec<&str> = path.split(':').collect();
    let first: Vec<&str> = bare.split(':').collect();
    assert_eq!(
        &entries[..first.len().min(entries.len())],
        &first[..],
        "the profile's PATH comes first"
    );
    for dir in extra {
        assert!(entries.contains(&dir.as_str()), "{dir} of the login PATH is missing from {path}");
    }
    let unique: std::collections::BTreeSet<&str> = entries.iter().copied().collect();
    assert_eq!(entries.len(), unique.len(), "each directory once: {path}");
    let _ = std::fs::remove_dir_all(&scratch);
}

#[cfg(target_os = "linux")]
#[test]
fn remote_scope_never_probes_a_profile_path_runner() {
    use std::io::Write as _;
    use std::process::{Command as StdCommand, Stdio};

    let root = std::env::temp_dir().join(format!("acpmux-remote-scope-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let runner = root.join("systemd-run");
    let marker = root.join("probed");
    let mut writer = StdCommand::new("/bin/sh")
        .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
        .arg(&runner)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    writeln!(
        writer.stdin.take().unwrap(),
        "#!/bin/sh\nprintf probed >{}\nexit 1",
        marker.display()
    )
    .unwrap();
    assert!(writer.wait().unwrap().success());
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/usr/bin/true"],
        "env": {
            "ACPMUX_REMOTE_ENV_POLICY": "1",
            "PATH": root
        }
    }))
    .unwrap();
    let _ = harness_command(
        "remote",
        &profile,
        &std::env::temp_dir(),
        None,
        Some(("session", "remote")),
    )
    .unwrap();
    assert!(!marker.exists(), "remote launch probed profile-controlled systemd-run");
    let _ = std::fs::remove_dir_all(&root);
}

/// A daemon started with Claude Code's login in its env gave it to Codex,
/// which wrote it to `~/.codex/shell_snapshots` (machine-vault-e2e,
/// 2026-11-04). Each harness loses the other's login, whatever env set it;
/// its own, and a value its profile sets on purpose, still pass.
#[test]
fn an_agent_never_inherits_another_harness_login() {
    use crate::config::HarnessKind;
    let profile = |kind, argv: &str, env: serde_json::Value| {
        let mut p: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": [argv], "env": env})).unwrap();
        p.kind = kind;
        p
    };
    let removed = |p: &HarnessProfile, key: &str| {
        let cmd = harness_command("local", p, &std::env::temp_dir(), None, None).unwrap();
        cmd.as_std().get_envs().any(|(k, v)| k == key && v.is_none())
    };
    let codex = profile(HarnessKind::Acp, "codex-acp", serde_json::json!({}));
    let claude = profile(HarnessKind::ClaudeStdio, "claude", serde_json::json!({}));
    for key in ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY"] {
        assert!(removed(&codex, key), "Codex inherits {key}");
        // Not `removed`: inside a Claude Code shell the nested scrub removes these too.
        assert!(
            !super::super::foreign_login::foreign_login_keys("claude").any(|k| k == key),
            "Claude Code loses its own {key}"
        );
    }
    for key in ["OPENAI_API_KEY", "CODEX_HOME"] {
        assert!(removed(&claude, key), "Claude Code inherits {key}");
        assert!(!removed(&codex, key), "Codex loses its own {key}");
    }
    // OpenCode signs in with provider keys, never with another harness's sign-in.
    let opencode = profile(HarnessKind::Acp, "opencode", serde_json::json!({}));
    assert!(removed(&opencode, "CLAUDE_CODE_OAUTH_TOKEN") && removed(&opencode, "CODEX_HOME"));
    // Not `removed`: inside a Claude Code shell the nested scrub removes ANTHROPIC_* too.
    let opencode_loses =
        |key: &str| super::super::foreign_login::foreign_login_keys("opencode").any(|k| k == key);
    assert!(!opencode_loses("ANTHROPIC_API_KEY") && !opencode_loses("OPENAI_API_KEY"));
    // A provider key in the daemon's own env reaches OpenCode, never Claude Code or Codex.
    for key in ["OPENROUTER_API_KEY", "GROQ_API_KEY"] {
        assert!(removed(&claude, key) && removed(&codex, key), "{key} reaches Claude or Codex");
        assert!(!removed(&opencode, key), "OpenCode loses {key}");
    }
    // A value the profile sets is the person's choice and passes.
    let chosen =
        profile(HarnessKind::Acp, "codex-acp", serde_json::json!({"ANTHROPIC_API_KEY": "own"}));
    let cmd = harness_command("local", &chosen, &std::env::temp_dir(), None, None).unwrap();
    let env = command_env(&cmd);
    assert_eq!(
        env.iter().find(|(k, _)| k == "ANTHROPIC_API_KEY").map(|(_, v)| v.as_str()),
        Some("own")
    );
}
