use super::*;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

struct Machine {
    root: PathBuf,
    home: PathBuf,
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn machine(kind: &str) -> Machine {
    static N: AtomicU32 = AtomicU32::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let root =
        std::env::temp_dir().join(format!("acpmux-claude-cloud-auth-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/vm-kind"), format!("{kind}\n")).unwrap();
    std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
    std::fs::write(
        root.join("etc/cmux/model-plane.env"),
        "export CMUX_CODEROUTER_URL='https://coderouter.cmux.internal'\n\
             export ANTHROPIC_BASE_URL='https://coderouter.cmux.internal'\n\
             export ANTHROPIC_API_KEY='cmux-vm-edge-placeholder'\n",
    )
    .unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    Machine { root, home }
}

async fn pair(m: &Machine, var: &[(&str, &str)], dns: bool) -> Option<[(String, String); 2]> {
    let mut env: BTreeMap<String, String> =
        var.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    env.insert("HOME".to_owned(), m.home.to_string_lossy().into_owned());
    let map = env.clone();
    let var = move |k: &str| map.get(k).cloned();
    let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
    team_pair(&inputs, &env, None, &m.home, |_| async move { dns }).await
}

#[tokio::test]
async fn a_credential_in_managed_settings_keeps_own_even_when_team_is_chosen() {
    let m = machine("owner");
    let team = [("CMUX_CLAUDE_AUTH", "team")];
    assert!(pair(&m, &team, true).await.is_some());
    let managed = m.root.join(MANAGED_SETTINGS);
    std::fs::create_dir_all(managed.parent().unwrap()).unwrap();
    for body in [
        r#"{"env":{"ANTHROPIC_AUTH_TOKEN":"managed"}}"#,
        r#"{"env":{"CLAUDE_CODE_USE_BEDROCK":true}}"#,
        r#"{"apiKeyHelper":"/bin/key"}"#,
        "not json",
    ] {
        std::fs::write(&managed, body).unwrap();
        assert_eq!(pair(&m, &team, true).await, None, "{body}");
    }
    // Managed settings with no credential leave team mode as chosen.
    std::fs::write(&managed, r#"{"permissions":{"deny":[]}}"#).unwrap();
    assert!(pair(&m, &team, true).await.is_some());
}

#[tokio::test]
async fn a_personal_endpoint_in_a_settings_file_keeps_own() {
    let m = machine("owner");
    assert!(pair(&m, &[], true).await.is_some());
    std::fs::write(
        m.home.join(".claude/settings.json"),
        r#"{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example.test"}}"#,
    )
    .unwrap();
    assert_eq!(pair(&m, &[], true).await, None);
}

#[tokio::test]
async fn a_claude_with_no_sign_in_gets_the_model_plane_pair() {
    let m = machine("owner");
    let got = pair(&m, &[], true).await.expect("team");
    assert_eq!(
        got[0],
        ("ANTHROPIC_BASE_URL".to_owned(), "https://coderouter.cmux.internal".to_owned())
    );
    assert_eq!(got[1], ("ANTHROPIC_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()));
    // The origin does not resolve: team mode could not work, so Claude shows its own sign-in.
    assert_eq!(pair(&m, &[], false).await, None);
}

#[tokio::test]
async fn a_sign_in_a_choice_or_a_persons_pair_keeps_own() {
    let m = machine("owner");
    assert_eq!(pair(&m, &[("ANTHROPIC_API_KEY", "sk-own")], true).await, None);
    assert_eq!(pair(&m, &[("ANTHROPIC_BASE_URL", "https://api.example.test")], true).await, None);
    assert_eq!(pair(&m, &[("CLAUDE_CODE_OAUTH_TOKEN", "t")], true).await, None);
    assert_eq!(pair(&m, &[("CMUX_CLAUDE_AUTH", "own")], true).await, None);
    let dir = m.home.join(".config/cmux/agent-auth");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("claude"), "own\n").unwrap();
    assert_eq!(pair(&m, &[], true).await, None);
    // `cr use team` over a sign-in of its own: team.
    std::fs::write(dir.join("claude"), "team\n").unwrap();
    std::fs::write(m.home.join(".claude/.credentials.json"), r#"{"claudeAiOauth":{"a":1}}"#)
        .unwrap();
    assert!(pair(&m, &[], true).await.is_some());
    // No choice: the sign-in keeps own.
    std::fs::remove_file(dir.join("claude")).unwrap();
    assert_eq!(pair(&m, &[], true).await, None);
    // The env pin wins over it.
    assert!(pair(&m, &[("CMUX_CLAUDE_AUTH", "team")], true).await.is_some());
    std::fs::remove_file(m.home.join(".claude/.credentials.json")).unwrap();
    assert!(pair(&m, &[], true).await.is_some());
    // A key from the vault or `machine.env` is in the effective env: own.
    assert_eq!(pair(&m, &[("ANTHROPIC_AUTH_TOKEN", "t")], true).await, None);
    // Settings credentials and helpers, and the `.claude.json` API key, keep own too.
    std::fs::write(m.home.join(".claude/settings.json"), r#"{"apiKeyHelper":"/bin/key"}"#).unwrap();
    assert_eq!(pair(&m, &[], true).await, None);
    std::fs::remove_file(m.home.join(".claude/settings.json")).unwrap();
    std::fs::write(m.home.join(".claude.json"), r#"{"primaryApiKey":"sk-own"}"#).unwrap();
    assert_eq!(pair(&m, &[], true).await, None);
}

fn team_pair_value() -> [(String, String); 2] {
    [
        ("ANTHROPIC_BASE_URL".to_owned(), "https://coderouter.cmux.internal".to_owned()),
        ("ANTHROPIC_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()),
    ]
}

#[test]
fn team_mode_clears_personal_credentials_and_keeps_a_routes_list() {
    let mut env = BTreeMap::from([
        ("ANTHROPIC_AUTH_TOKEN".to_owned(), "personal".to_owned()),
        ("CLAUDE_CODE_OAUTH_TOKEN".to_owned(), "personal".to_owned()),
        (crate::routes::UNSET_KEY.to_owned(), "OPENAI_API_KEY".to_owned()),
    ]);
    let mut argv: Vec<String> =
        ["claude", "--settings", r#"{"model":"opus"}"#, "--verbose"].map(str::to_owned).to_vec();
    let flag = flag_settings(&argv[1..], Path::new("/")).unwrap();
    apply_team(
        &mut env,
        &mut argv,
        flag.as_ref(),
        team_pair_value(),
        "x-personal: 1\nx-cmux-workspace-id: ws-1",
        false,
    );
    // Only the usage attribution header stays, in place of the inherited value.
    assert_eq!(env[HEADERS], "x-cmux-workspace-id: ws-1");
    for key in TEAM_CLEARS.iter().filter(|k| **k != HEADERS) {
        assert!(!env.contains_key(*key));
    }
    let unset: Vec<&str> = env[crate::routes::UNSET_KEY].split(',').collect();
    assert_eq!(unset[0], "OPENAI_API_KEY");
    assert!(TEAM_CLEARS.iter().filter(|k| **k != HEADERS).all(|k| unset.contains(k)));
    assert!(!unset.contains(&HEADERS));
    assert_eq!(env["ANTHROPIC_API_KEY"], PLACEHOLDER_KEY);
    assert_eq!(marked_pair(&env), Some(team_pair_value()));
    // One --settings, last: the launch's own merged with the pair and the clears.
    assert_eq!(argv[..2], ["claude", "--verbose"]);
    assert_eq!(argv.iter().filter(|a| *a == "--settings").count(), 1);
    assert_eq!(argv[argv.len() - 2], "--settings");
    let settings: Value = serde_json::from_str(argv.last().unwrap()).unwrap();
    assert_eq!(settings["model"], "opus");
    assert_eq!(settings["env"]["ANTHROPIC_API_KEY"], PLACEHOLDER_KEY);
    for key in TEAM_CLEARS.iter().filter(|k| **k != HEADERS) {
        assert_eq!(settings["env"][*key], "");
    }
    assert_eq!(settings["env"][HEADERS], "x-cmux-workspace-id: ws-1");
    for helper in HELPERS {
        assert_eq!(settings[helper], "");
    }
    // A remote chain keeps its argv; its own settings take the pair (remote_sandbox.rs).
    let mut env = BTreeMap::new();
    let mut argv = vec!["claude".to_owned()];
    apply_team(&mut env, &mut argv, None, team_pair_value(), "x-personal: 1", true);
    assert_eq!(argv, ["claude"]);
    assert!(marked_pair(&env).is_some());
    // No usage header: the name goes on the unset list.
    assert!(!env.contains_key(HEADERS));
    assert!(env[crate::routes::UNSET_KEY].split(',').any(|k| k == HEADERS));
}

#[test]
fn only_claude_itself_is_a_launch_team_mode_takes() {
    let argv = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert!(launches_claude_itself(&argv(&["claude"])));
    assert!(launches_claude_itself(&argv(&["/usr/local/bin/claude", "--verbose"])));
    assert!(!launches_claude_itself(&argv(&["/usr/local/bin/sr", "claude", "proxy"])));
    assert!(!launches_claude_itself(&argv(&["cr", "fast"])));
    assert!(!launches_claude_itself(&argv(&["coderouter", "fast"])));
    assert!(!launches_claude_itself(&[]));
}

#[test]
fn flag_settings_reads_the_last_inline_or_file_value() {
    let m = machine("owner");
    let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert_eq!(flag_settings(&words(&["--verbose"]), &m.home).unwrap(), None);
    let inline = flag_settings(
        &words(&["--settings", r#"{"env":{"A":"1"}}"#, "--settings={\"env\":{\"A\":\"2\"}}"]),
        &m.home,
    )
    .unwrap()
    .unwrap();
    assert_eq!(inline["env"]["A"], "2");
    std::fs::write(m.home.join("s.json"), r#"{"apiKeyHelper":"/bin/key"}"#).unwrap();
    let file = flag_settings(&words(&["--settings", "s.json"]), &m.home).unwrap().unwrap();
    assert_eq!(file["apiKeyHelper"], "/bin/key");
    assert!(flag_settings(&words(&["--settings", "missing.json"]), &m.home).is_err());
    assert!(flag_settings(&words(&["--settings", "[1]"]), &m.home).is_err());
}

#[tokio::test]
async fn a_sign_in_in_the_launchs_own_settings_flag_keeps_own() {
    let m = machine("owner");
    let env = BTreeMap::from([("HOME".to_owned(), m.home.to_string_lossy().into_owned())]);
    let read = env.clone();
    let var = move |k: &str| read.get(k).cloned();
    let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
    let flag = |v: Value| v.as_object().cloned();
    let (inputs, home) = (&inputs, m.home.as_path());
    let pair = |f: Option<Map<String, Value>>| {
        let env = env.clone();
        async move { team_pair(inputs, &env, f.as_ref(), home, |_| async { true }).await }
    };
    assert!(pair(None).await.is_some());
    let token = flag(serde_json::json!({"env": {"ANTHROPIC_AUTH_TOKEN": "t"}}));
    assert_eq!(pair(token).await, None);
    let helper = flag(serde_json::json!({"apiKeyHelper": "/bin/key"}));
    assert_eq!(pair(helper).await, None);
    let endpoint = flag(serde_json::json!({"env": {"ANTHROPIC_BASE_URL": "https://x.test"}}));
    assert_eq!(pair(endpoint).await, None);
    // A provider switch as a JSON boolean or number is the person's provider too.
    let bedrock = flag(serde_json::json!({"env": {"CLAUDE_CODE_USE_BEDROCK": true}}));
    assert_eq!(pair(bedrock).await, None);
    let vertex = flag(serde_json::json!({"env": {"CLAUDE_CODE_USE_VERTEX": 1}}));
    assert_eq!(pair(vertex).await, None);
    let off = flag(serde_json::json!({"env": {"CLAUDE_CODE_USE_BEDROCK": false}}));
    assert!(pair(off).await.is_some());
    // Settings with no credential stay team.
    assert!(pair(flag(serde_json::json!({"model": "opus"}))).await.is_some());
}

#[tokio::test]
async fn only_an_owner_cloud_image_with_a_team_plane() {
    assert_eq!(pair(&machine("team"), &[], true).await, None);
    let m = machine("owner");
    std::fs::write(
        m.root.join("etc/cmux/model-plane.env"),
        "export OPENAI_BASE_URL='https://x/v1'\n",
    )
    .unwrap();
    assert_eq!(pair(&m, &[], true).await, None);
}
