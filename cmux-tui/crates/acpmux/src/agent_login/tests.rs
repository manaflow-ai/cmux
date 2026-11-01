use super::parse::{allowed_url, device_code, offer, strip_terminal};
use super::*;

/// `claude auth login` with plain pipes (Claude Code 2.1.305, Linux).
const CLAUDE_PLAIN: &str = "Opening browser to sign in…\nIf the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&state=abc123\nPaste code here if prompted > ";

/// The same under a terminal: the link wrapped in an OSC-8 hyperlink, colours around it.
const CLAUDE_PTY: &str = "\u{1b}[2mOpening browser to sign in…\u{1b}[22m\r\nIf the browser didn't open, visit: \u{1b}]8;;https://claude.com/cai/oauth/authorize?code=true&state=abc123\u{1b}\\https://claude.com/cai/oauth/authorize?code=true&state=abc123\u{1b}]8;;\u{1b}\\\r\nPaste code here if prompted > ";

/// `codex login --device-auth` (codex-cli 0.162.1).
const CODEX: &str = "\u{1b}[1mWelcome to Codex\u{1b}[0m\n\n1. Open this link in your browser and sign in to your account\n   \u{1b}[94mhttps://auth.openai.com/codex/device\u{1b}[0m\n\n2. Enter this one-time code \u{1b}[90m(expires in 15 minutes)\u{1b}[0m\n   \u{1b}[94mABCD-EFGHI\u{1b}[0m\n\n\u{1b}[90mDevice codes are a common phishing target. Never share this code.\u{1b}[0m\n";

#[test]
fn claude_link_from_plain_pipes() {
    let got = offer(Agent::Claude, CLAUDE_PLAIN).expect("a link");
    assert!(got.url.starts_with("https://claude.com/cai/oauth/authorize?code=true&client_id="));
    assert!(got.url.ends_with("&state=abc123"), "{}", got.url);
    assert_eq!(got.user_code, None);
}

#[test]
fn claude_link_from_a_terminal_hyperlink() {
    let (plain, links) = strip_terminal(CLAUDE_PTY);
    assert!(!plain.contains('\u{1b}') && !plain.contains('\r'), "{plain:?}");
    assert_eq!(links, ["https://claude.com/cai/oauth/authorize?code=true&state=abc123"]);
    let got = offer(Agent::Claude, CLAUDE_PTY).expect("a link");
    assert_eq!(got.url, "https://claude.com/cai/oauth/authorize?code=true&state=abc123");
}

#[test]
fn a_link_still_arriving_is_not_offered() {
    let partial =
        "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=tr";
    assert_eq!(offer(Agent::Claude, partial), None);
    // An OSC-8 sequence still open is not a link yet either.
    assert_eq!(offer(Agent::Claude, "visit: \u{1b}]8;;https://claude.com/cai/oauth"), None);
}

#[test]
fn codex_link_and_code() {
    let got = offer(Agent::Codex, CODEX).expect("an offer");
    assert_eq!(got.url, "https://auth.openai.com/codex/device");
    assert_eq!(got.user_code.as_deref(), Some("ABCD-EFGHI"));
    // Before the code's line is complete, nothing is offered.
    let cut = &CODEX[..CODEX.find("ABCD-EF").unwrap() + 7];
    assert_eq!(offer(Agent::Codex, cut), None);
}

#[test]
fn device_code_shape() {
    assert_eq!(device_code("Enter this one-time code\n   ab-cd\n"), None);
    assert_eq!(device_code("Enter this one-time code\n   ----\n"), None);
    assert_eq!(device_code("Enter this one-time code\n   AB\n"), None);
    assert_eq!(
        device_code("Enter this one-time code\n\n  WXYZ-1234\n").as_deref(),
        Some("WXYZ-1234")
    );
}

#[test]
fn only_allowed_https_hosts() {
    for ok in [
        "https://claude.com/cai/oauth/authorize?x=1",
        "https://claude.ai/oauth",
        "https://platform.claude.com/oauth/code/callback",
        "https://console.anthropic.com/x",
        "https://auth.anthropic.com/x",
        "https://auth.openai.com/codex/device",
        "https://AUTH.OPENAI.COM/codex/device",
    ] {
        assert!(allowed_url(ok).is_some(), "{ok}");
    }
    for bad in [
        "http://claude.com/cai/oauth",
        "https://claude.com.evil.example/x",
        "https://evil.example/?https://claude.com/",
        "https://user@claude.com/x",
        "https://claude.com:8443/x",
        "https://claude.com\\@evil.example/x",
        "https://claude.com/x y",
        "https://cláude.com/x",
        "https://",
        "javascript:alert(1)",
    ] {
        assert_eq!(allowed_url(bad), None, "{bad}");
    }
    // A disallowed link never stands in for the real one.
    let text = "visit: https://evil.example/login \nthen https://auth.openai.com/codex/device\n";
    assert_eq!(
        super::parse::first_url(text, &[]).as_deref(),
        Some("https://auth.openai.com/codex/device")
    );
    assert_eq!(offer(Agent::Claude, "visit: https://evil.example/login\n"), None);
}

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "agent-login-{tag}-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn shared_machine_by_vm_kind() {
    let root = dir("kind");
    let m = Machine { root: root.clone(), home: root.join("home") };
    // No marker: not a cmux Cloud team machine.
    assert!(!m.shared());
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/vm-kind"), "owner\n").unwrap();
    assert!(!m.shared());
    std::fs::write(root.join("etc/cmux/vm-kind"), "team\n").unwrap();
    assert!(m.shared());
    std::fs::write(root.join("etc/cmux/vm-kind"), "").unwrap();
    assert!(m.shared());
    assert_eq!(m.refuse_shared().unwrap_err().reason, reason::SHARED_MACHINE);
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn shared_machine_refuses_start_and_key() {
    let root = dir("shared");
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/vm-kind"), "team\n").unwrap();
    let m = Machine { root: root.clone(), home: root.join("home") };
    // Refused before anything runs: the program does not exist.
    let cli = Cli { program: root.join("no-such-cli").display().to_string(), ..Cli::default() };
    let e = start(&m, &cli, Agent::Claude).await.unwrap_err();
    assert_eq!(e.reason, reason::SHARED_MACHINE);
    let e = save_api_key(&m, &cli, Agent::Claude, "sk-ant-test-1234").await.unwrap_err();
    assert_eq!(e.reason, reason::SHARED_MACHINE);
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_missing_cli_is_cli_missing() {
    let root = dir("missing");
    let m = Machine { root: root.clone(), home: root.join("home") };
    let mut cli = Cli { program: root.join("no-such-cli").display().to_string(), ..Cli::default() };
    cli.env.insert("CODEX_HOME".into(), root.join("codex").display().to_string());
    let e = start(&m, &cli, Agent::Codex).await.unwrap_err();
    assert_eq!(e.reason, reason::CLI_MISSING, "{e:?}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn own_choice_only_on_a_cloud_image() {
    let root = dir("own");
    let home = root.join("home");
    let m = Machine { root: root.clone(), home: home.clone() };
    assert!(!m.choose_own(Agent::Claude).unwrap());
    assert!(!home.join(".config/cmux/agent-auth/claude").exists());
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
    assert!(m.choose_own(Agent::Codex).unwrap());
    let file = home.join(".config/cmux/agent-auth/codex");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "own\n");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&file), 0o600);
        assert_eq!(mode(file.parent().unwrap()), 0o700);
    }
    // A team choice the person made before is replaced.
    std::fs::write(home.join(".config/cmux/agent-auth/claude"), "team\n").unwrap();
    assert!(m.choose_own(Agent::Claude).unwrap());
    assert_eq!(
        std::fs::read_to_string(home.join(".config/cmux/agent-auth/claude")).unwrap(),
        "own\n"
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn claude_key_merges_into_settings() {
    let store = dir("settings");
    std::fs::write(
        store.join("settings.json"),
        r#"{"model":"opus","env":{"FOO":"1","ANTHROPIC_API_KEY":"old"},"permissions":{"allow":["Bash"]}}"#,
    )
    .unwrap();
    merge_claude_api_key(&store, "sk-ant-new").unwrap();
    let v: Value =
        serde_json::from_slice(&std::fs::read(store.join("settings.json")).unwrap()).unwrap();
    assert_eq!(v["model"], "opus");
    assert_eq!(v["env"]["FOO"], "1");
    assert_eq!(v["env"]["ANTHROPIC_API_KEY"], "sk-ant-new");
    assert_eq!(v["permissions"]["allow"][0], "Bash");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(store.join("settings.json")).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    // No temp file is left beside it.
    let names: Vec<_> =
        std::fs::read_dir(&store).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names.len(), 1, "{names:?}");
    // A missing file and home are made.
    let fresh = store.join("fresh");
    merge_claude_api_key(&fresh, "sk-ant-x").unwrap();
    let v: Value =
        serde_json::from_slice(&std::fs::read(fresh.join("settings.json")).unwrap()).unwrap();
    assert_eq!(v, serde_json::json!({"env": {"ANTHROPIC_API_KEY": "sk-ant-x"}}));
    // A file that is not an object is never replaced.
    std::fs::write(store.join("settings.json"), "[1]").unwrap();
    assert!(merge_claude_api_key(&store, "k").is_err());
    std::fs::write(store.join("settings.json"), "{not json").unwrap();
    assert!(merge_claude_api_key(&store, "k").is_err());
    assert_eq!(std::fs::read_to_string(store.join("settings.json")).unwrap(), "{not json");
    let _ = std::fs::remove_dir_all(&store);
}

#[test]
fn signed_in_reads_the_stores() {
    let store = dir("stores");
    assert!(!signed_in_at(Agent::Claude, &store));
    std::fs::write(store.join(".credentials.json"), r#"{"mcpOAuth":{}}"#).unwrap();
    assert!(!signed_in_at(Agent::Claude, &store));
    std::fs::write(store.join(".credentials.json"), r#"{"claudeAiOauth":{"accessToken":"t"}}"#)
        .unwrap();
    assert!(signed_in_at(Agent::Claude, &store));
    assert!(!signed_in_at(Agent::Codex, &store));
    std::fs::write(store.join("auth.json"), r#"{"tokens":{}}"#).unwrap();
    assert!(!signed_in_at(Agent::Codex, &store));
    std::fs::write(store.join("auth.json"), r#"{"tokens":{"id_token":"t"}}"#).unwrap();
    assert!(signed_in_at(Agent::Codex, &store));
    std::fs::write(store.join("auth.json"), r#"{"OPENAI_API_KEY":"sk-x"}"#).unwrap();
    assert!(signed_in_at(Agent::Codex, &store));
    let _ = std::fs::remove_dir_all(&store);
}

#[test]
fn codes_and_keys_are_one_line() {
    assert!(one_line("abc#def", 64));
    assert!(!one_line("", 64));
    assert!(!one_line("abc\ndef", 64));
    assert!(!one_line("abc def", 64));
    assert!(!one_line("abc\u{1b}", 64));
    assert!(!one_line(&"a".repeat(65), 64));
}

#[test]
fn model_plane_env_never_reaches_the_cli() {
    let mut cli = Cli { program: "/bin/true".into(), ..Cli::default() };
    cli.env.insert("ANTHROPIC_BASE_URL".into(), "https://router.example".into());
    cli.env.insert("CLAUDE_CONFIG_DIR".into(), "/tmp/claude-home".into());
    let cmd = cli.command(&["auth", "login"], Path::new("/tmp"));
    let envs: BTreeMap<String, Option<String>> = cmd
        .as_std()
        .get_envs()
        .map(|(k, v)| {
            (k.to_string_lossy().into_owned(), v.map(|v| v.to_string_lossy().into_owned()))
        })
        .collect();
    for key in MODEL_PLANE_ENV {
        assert_eq!(envs.get(*key), Some(&None), "{key} is removed");
    }
    assert_eq!(envs.get("DISPLAY"), Some(&None));
    assert_eq!(envs.get("BROWSER"), Some(&Some("true".into())));
    assert_eq!(envs.get("CMUX_CLAUDE_AUTH"), Some(&Some("own".into())));
    assert_eq!(envs.get("CLAUDE_CONFIG_DIR"), Some(&Some("/tmp/claude-home".into())));
}
