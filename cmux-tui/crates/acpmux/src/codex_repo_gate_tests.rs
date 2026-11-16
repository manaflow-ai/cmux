use super::*;
use std::ffi::OsStr;

/// Codex's trust hash of a lone PreToolUse command hook, written out here rather than through
/// cmux-tui-hooks: sha256 over the sorted compact JSON of its normalized identity.
fn expected_hash(command: &str, timeout: u64) -> String {
    use sha2::Digest as _;
    let identity = serde_json::json!({
        "event_name": "pre_tool_use",
        "hooks": [{"async": false, "command": command, "timeout": timeout, "type": "command"}],
    });
    format!("sha256:{:x}", sha2::Sha256::digest(serde_json::to_vec(&identity).unwrap()))
}

#[test]
fn the_flags_enable_hooks_add_one_pre_tool_use_hook_and_trust_it() {
    let command = hook_command("/opt/cmux/bin/cmux-tui", &["acp".into()]);
    assert_eq!(command, "'/opt/cmux/bin/cmux-tui' 'acp' '__codex-repo-gate'||exit 2");
    let flags = hook_flags(&command).unwrap();
    assert_eq!(flags.len(), 6, "{flags:?}");
    assert_eq!(&flags[..2], ["--enable", "hooks"]);
    assert_eq!(flags[2], "-c");
    let hook: toml::Table = flags[3].parse().unwrap();
    let hook = &hook["hooks"]["PreToolUse"][0]["hooks"][0];
    assert_eq!(hook["type"].as_str(), Some("command"));
    assert_eq!(hook["command"].as_str(), Some(command.as_str()));
    assert_eq!(hook["timeout"].as_integer(), Some(HOOK_TIMEOUT_SECS as i64));
    assert_eq!(flags[4], "-c");
    let state: toml::Table = flags[5].parse().unwrap();
    let state = state["hooks"]["state"].as_table().unwrap();
    assert_eq!(state.len(), 1, "only its own entry: the user's keep their trust");
    let entry = &state["/<session-flags>/config.toml:pre_tool_use:0:0"];
    assert_eq!(entry["trusted_hash"].as_str(), Some(expected_hash(&command, 90).as_str()));
}

#[test]
fn the_hook_outlasts_the_wait_it_runs() {
    assert!(Duration::from_secs(HOOK_TIMEOUT_SECS) > cmux_git::native_hook::WAIT);
}

#[test]
fn a_launch_counts_as_gated_only_with_both_the_switch_and_its_own_hook() {
    let os = |args: &[String]| args.iter().map(OsStr::new).collect::<Vec<_>>();
    let app_server = vec!["app-server".to_owned()];
    let gated = gated_args(&app_server).unwrap();
    assert_eq!(gated.last().map(String::as_str), Some("app-server"), "options go first");
    assert!(crate::codex_app_server::is_launch("codex", &gated));
    assert!(in_args(os(&gated)));
    assert!(!in_args(os(&app_server)));
    let own_hook: Vec<String> =
        ["--enable", "hooks", "-c", "hooks.PreToolUse=[]", "app-server"].map(String::from).to_vec();
    assert!(!in_args(os(&own_hook)), "a user's own hook is not this one");
    let no_switch: Vec<String> = gated[2..].to_vec();
    assert!(!in_args(os(&no_switch)), "a hook Codex never enabled runs nothing");
}

#[test]
fn versions_from_the_floor_count() {
    assert!(at_least("0.130.0", MIN_VERSION));
    assert!(at_least("0.160.0", MIN_VERSION));
    assert!(at_least("0.131.0-alpha.2", MIN_VERSION));
    assert!(!at_least("0.120.0", MIN_VERSION));
    assert!(!at_least("not a version", MIN_VERSION));
}

/// A stand-in `codex` in its own folder that prints `version`.
fn fake_codex(version: &str) -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("codex");
    std::fs::write(&path, format!("#!/bin/sh\necho 'codex-cli {version}'\n")).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let program = path.to_string_lossy().into_owned();
    (dir, program)
}

#[test]
fn only_a_supported_codex_in_a_filling_checkout_gets_the_hook() {
    let repo = tempfile::tempdir().unwrap();
    let cwd = repo.path().canonicalize().unwrap().join("repo");
    std::fs::create_dir(&cwd).unwrap();
    let (_new, new) = fake_codex("0.160.0");
    let (_old, old) = fake_codex("0.120.0");
    let args = vec!["app-server".to_owned()];
    assert!(!wanted(&new, &args, &cwd, &[]), "no sync: nothing to wait for");
    let mut sync = cmux_git::sync_barrier::Sync::begin(&cwd).unwrap();
    assert!(wanted(&new, &args, &cwd, &[]), "short of the head");
    sync.head_ready();
    assert!(wanted(&new, &args, &cwd, &[]), "at the head");
    assert!(!wanted(&old, &args, &cwd, &[]), "too old to start with the hook");
    let own = vec!["-c".to_owned(), "hooks.Stop=[]".to_owned(), "app-server".to_owned()];
    assert!(!wanted(&new, &own, &cwd, &[]), "its own command line names hooks");
    let adapter = vec!["--port".to_owned(), "1".to_owned()];
    assert!(!wanted(&new, &adapter, &cwd, &[]), "not app-server");
    // By name on the launch's PATH, as the harness finds it.
    let dir = Path::new(&new).parent().unwrap().to_string_lossy().into_owned();
    assert!(wanted("codex", &args, &cwd, &[("PATH".into(), Some(dir))]));
    sync.complete().unwrap();
    assert!(!wanted(&new, &args, &cwd, &[]), "whole: nothing to wait for");
}

#[test]
fn a_refused_call_reads_as_claudes_does() {
    let text = refusal("repository synchronization did not finish");
    assert!(text.starts_with("Repository sync is not ready: repository synchronization"), "{text}");
}

/// The hook holds a call while the checkout fills and lets it through once it is whole; a
/// checkout still filling at the wait's end refuses it.
#[test]
fn the_hook_waits_for_the_whole_checkout_then_lets_the_call_through() {
    let repo = tempfile::tempdir().unwrap();
    let cwd = repo.path().canonicalize().unwrap().join("repo");
    std::fs::create_dir(&cwd).unwrap();
    let input = serde_json::json!({
        "cwd": cwd, "tool_name": "apply_patch", "tool_input": {"command": "*** Begin Patch"}
    });
    let mut sync = cmux_git::sync_barrier::Sync::begin(&cwd).unwrap();
    sync.head_ready();
    let refused = check(&input, Duration::from_millis(200)).unwrap_err();
    assert!(refused.starts_with("Repository sync is not ready"), "{refused}");
    let started = std::time::Instant::now();
    let filler = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        sync.complete().unwrap();
    });
    check(&input, Duration::from_secs(10)).unwrap();
    assert!(started.elapsed() >= Duration::from_millis(300), "it waited for the fill");
    filler.join().unwrap();
    check(&input, Duration::ZERO).unwrap();
}
