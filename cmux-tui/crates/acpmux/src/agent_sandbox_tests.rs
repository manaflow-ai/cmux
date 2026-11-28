use super::*;

fn words(w: &[&str]) -> Vec<String> {
    w.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn reads_both_choices_and_defaults_what_it_does_not_know() {
    let doc = json!({"agents": {"sandbox": {"mode": "workspaceWrite", "network": "allow"}}});
    assert_eq!(
        Sandbox::from_doc(&doc),
        Sandbox { mode: Mode::WorkspaceWrite, network: Network::Allow }
    );
    let flat =
        json!({"agents.sandbox.mode": "permissionMode", "agents.sandbox.network": "harness"});
    assert_eq!(Sandbox::from_doc(&flat), Sandbox::default());
    let odd = json!({"agents.sandbox.mode": "everything", "agents.sandbox.network": true});
    assert_eq!(Sandbox::from_doc(&odd), Sandbox::default());
    assert_eq!(Sandbox::from_doc(&json!({})), Sandbox::default());
}

#[test]
fn workspace_write_turns_claude_codes_sandbox_on_over_its_own_settings() {
    let on = Sandbox { mode: Mode::WorkspaceWrite, network: Network::Harness };
    let cwd = std::env::temp_dir();
    let mut argv = words(&[
        "claude",
        "--settings",
        r#"{"env":{"A":"1"},"sandbox":{"excludedCommands":["git"],"enabled":false}}"#,
        "-p",
        "--",
        "--settings",
    ]);
    claude_argv(on, &mut argv, &cwd);
    assert_eq!(&argv[..2], ["claude", "-p"]);
    assert_eq!(argv[2], "--settings");
    let merged: Value = serde_json::from_str(&argv[3]).unwrap();
    assert_eq!(merged["env"]["A"], "1");
    assert_eq!(merged["sandbox"]["enabled"], true);
    assert_eq!(merged["sandbox"]["allowUnsandboxedCommands"], false);
    assert_eq!(merged["sandbox"]["excludedCommands"], json!(["git"]));
    assert_eq!(&argv[4..], ["--", "--settings"], "positional words stay");

    let mut plain = words(&["claude"]);
    claude_argv(Sandbox::default(), &mut plain, &cwd);
    assert_eq!(plain, ["claude"], "permissionMode adds nothing");

    let mut unreadable = words(&["claude", "--settings", "/nonexistent/settings.json"]);
    let before = unreadable.clone();
    claude_argv(on, &mut unreadable, &cwd);
    assert_eq!(unreadable, before);
}

#[test]
fn network_allow_adds_codexs_key_unless_it_is_set() {
    let allow = Sandbox { mode: Mode::PermissionMode, network: Network::Allow };
    let launch = words(&["app-server"]);
    assert_eq!(
        codex_args(allow, launch.clone(), || false),
        ["-c", "sandbox_workspace_write.network_access=true", "app-server"]
    );
    assert_eq!(codex_args(allow, launch.clone(), || true), ["app-server"]);
    assert_eq!(codex_args(Sandbox::default(), launch, || false), ["app-server"]);
}
