use super::parse::{allowed_url, auto_url, device_code, offer, strip_terminal};
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

/// The gateway fallback is off unless the daemon's environment says exactly on (founders turn
/// billing on first).
#[test]
fn gateway_fallback_is_off_by_default() {
    assert!(!gateway_fallback(None));
    for off in ["", "0", "false", "off", "no", "maybe"] {
        assert!(!gateway_fallback(Some(off)), "{off:?}");
    }
    for on in ["1", "true", "TRUE", "yes", "on", " on "] {
        assert!(gateway_fallback(Some(on)), "{on:?}");
    }
    assert_eq!(GATEWAY_FALLBACK_ENV, "CMUX_GATEWAY_FALLBACK");
}

#[test]
fn gateway_agents_are_claude_and_codex() {
    assert_eq!(gateway_agent("claude@gateway"), Some(Agent::Claude));
    assert_eq!(gateway_agent("codex@gateway"), Some(Agent::Codex));
    assert_eq!(gateway_agent("claude"), None);
    assert_eq!(gateway_agent("gemini@gateway"), None);
    assert_eq!(gateway_agent("@gateway"), None);
}

/// A fake image library: `cmux_agent_team_access` as the image's, answering from a file the test
/// writes, and only with the model plane loaded.
const FAKE_AGENT_AUTH: &str = r#"cmux_agent_team_access() {
  [ -n "${CMUX_CODEROUTER_URL-}" ] || return 2
  [ "$1" = claude ] || return 1
  return "$(cat "$HOME/access" 2>/dev/null || echo 1)"
}
"#;

#[tokio::test]
async fn gateway_access_asks_the_image() {
    let root = dir("gw-access");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let m = Machine { root: root.clone(), home: home.clone() };
    // Not a cmux Cloud image: no answer, and no choice recorded.
    assert_eq!(m.gateway_access(Agent::Claude).await, None);
    assert!(!m.choose_team(Agent::Claude).unwrap());
    assert!(!home.join(".config/cmux/agent-auth/claude").exists());
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/agent-auth.sh"), FAKE_AGENT_AUTH).unwrap();
    // No model plane: the image cannot ask.
    if std::env::var_os("CMUX_CODEROUTER_URL").is_none() {
        assert_eq!(m.gateway_access(Agent::Claude).await, None);
    }
    std::fs::write(
        root.join("etc/cmux/model-plane.env"),
        "CMUX_CODEROUTER_URL=http://127.0.0.1:9\n",
    )
    .unwrap();
    assert_eq!(m.gateway_access(Agent::Claude).await, Some(false));
    std::fs::write(home.join("access"), "0").unwrap();
    assert_eq!(m.gateway_access(Agent::Claude).await, Some(true));
    assert_eq!(m.gateway_access(Agent::Codex).await, Some(false));
    // Agents the image does not route are never asked.
    assert_eq!(m.gateway_access(Agent::Gemini).await, None);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn team_choice_is_cr_use_team() {
    let root = dir("gw-team");
    let home = root.join("home");
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
    let m = Machine { root: root.clone(), home: home.clone() };
    // An own choice before, and a kept access answer.
    assert!(m.choose_own(Agent::Claude).unwrap());
    std::fs::create_dir_all(home.join(".cache/cmux")).unwrap();
    std::fs::write(home.join(".cache/cmux/agent-access"), "claude=0\n").unwrap();
    assert!(m.choose_team(Agent::Claude).unwrap());
    let file = home.join(".config/cmux/agent-auth/claude");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "team\n");
    assert!(!home.join(".cache/cmux/agent-access").exists());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    }
    // Again, with no kept answer: still fine.
    assert!(m.choose_team(Agent::Claude).unwrap());
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

#[test]
fn login_command_pins_the_resolved_account_homes() {
    let mut cli = Cli { program: "/bin/true".into(), ..Cli::default() };
    cli.env.insert("HOME".into(), "/tmp/login-user".into());
    cli.env.insert("CODEX_HOME".into(), "/tmp/login-codex".into());
    cli.env.insert("CLAUDE_CONFIG_DIR".into(), "/tmp/login-claude".into());
    let cmd = cli.command(&["login"], Path::new("/tmp"));
    let env: BTreeMap<_, _> = cmd.as_std().get_envs().collect();
    for (agent, key) in [(Agent::Claude, "CLAUDE_CONFIG_DIR"), (Agent::Codex, "CODEX_HOME")] {
        assert_eq!(
            env.get(std::ffi::OsStr::new(key)).copied().flatten(),
            Some(cli.store(agent).as_os_str())
        );
    }
    // No profile home: the command still names the same imported or inherited home as lookup.
    let cli = Cli::default();
    let cmd = cli.command(&[], Path::new("/tmp"));
    let env: BTreeMap<_, _> = cmd.as_std().get_envs().collect();
    for key in ["HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
        if let Some(value) = cli.var(key) {
            assert_eq!(
                env.get(std::ffi::OsStr::new(key)).copied().flatten(),
                Some(std::ffi::OsStr::new(&value))
            );
        }
    }
}

#[test]
fn auto_url_is_an_allowed_link_back_to_localhost_callback() {
    let ok = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&scope=user%3Ainference&state=abc";
    assert_eq!(auto_url(&format!("{ok}\n")), Some((ok.to_owned(), 54545)));
    // The shim saves every argument on its own line: the link is found among them.
    assert_eq!(auto_url(&format!("--new-window\n{ok}\n")).map(|(_, p)| p), Some(54545));
    for bad in [
        // The manual link: its redirect shows a code to paste.
        "https://claude.com/cai/oauth/authorize?redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback",
        // Another host for the page, or for the redirect.
        "https://evil.example/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback",
        "https://claude.com/x?redirect_uri=http%3A%2F%2Fevil.example%3A54545%2Fcallback",
        "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost.evil.example%3A54545%2Fcallback",
        "https://claude.com/x?redirect_uri=http%3A%2F%2F127.0.0.1%3A54545%2Fcallback",
        // Another path, no port, a bad port, a second redirect, a broken escape.
        "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fother",
        "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%2Fcallback",
        "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A0%2Fcallback",
        "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A070%2Fcallback",
        "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A99999%2Fcallback",
        "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback&redirect_uri=http%3A%2F%2Flocalhost%3A2%2Fcallback",
        "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback%",
        "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback%+1",
        // Not https.
        "http://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback",
        "",
    ] {
        assert_eq!(auto_url(bad), None, "{bad}");
    }
}

#[cfg(unix)]
#[test]
fn browser_shim_saves_the_link_owner_only_and_opens_nothing() {
    use std::os::unix::fs::PermissionsExt;
    let folder = Folder::new(Agent::Claude).unwrap();
    let shim = folder.browser_shim().unwrap();
    assert_eq!(std::fs::metadata(&shim).unwrap().permissions().mode() & 0o777, 0o700);
    let link = "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A49152%2Fcallback&state=s";
    // A sibling test's fork can hold the just-written shim open until it execs (ETXTBSY,
    // `crate::test_exec`); the daemon runs it only once the login asks, long after.
    let status = (0..100)
        .find_map(|_| match std::process::Command::new(&shim).arg(link).status() {
            Err(e) if e.kind() == std::io::ErrorKind::ExecutableFileBusy => {
                std::thread::sleep(std::time::Duration::from_millis(20));
                None
            }
            other => Some(other.unwrap()),
        })
        .expect("the shim stayed busy");
    assert!(status.success());
    let saved = folder.0.join(AUTO_URL_FILE);
    assert_eq!(std::fs::metadata(&saved).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(folder.auto_url(), Some((link.to_owned(), 49152)));
    // A link out of the folder in its place is never read.
    std::fs::remove_file(&saved).unwrap();
    let elsewhere = folder.0.join("elsewhere");
    std::fs::write(&elsewhere, link).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &saved).unwrap();
    assert_eq!(folder.auto_url(), None);
}

/// Plausible `grok login --device-auth` outputs (its exact words are not pinned): the code on the
/// line naming it, on the line after it, quoted, after the link, and inside a link's query.
const GROK_SHAPES: &[(&str, &str, &str)] = &[
    // What grok 1.0.77 prints on Linux (`grok login --device-auth`, read on CI, code replaced).
    (
        "To sign in, open this URL in your browser:\n  https://accounts.x.ai/oauth2/device?user_code=WDJB-MJHT\nConfirm this code in your browser:\n  WDJB-MJHT\n\u{1b}[90mOnly continue with a code you requested. Don't share it with anyone.\u{1b}[0m\nWaiting for authorization...\n",
        "https://accounts.x.ai/oauth2/device?user_code=WDJB-MJHT",
        "WDJB-MJHT",
    ),
    (
        "To sign in, open https://accounts.x.ai/device in your browser\nand enter the code: WDJB-MJHT\nWaiting for authorization...\n",
        "https://accounts.x.ai/device",
        "WDJB-MJHT",
    ),
    (
        "\u{1b}[1mGrok login\u{1b}[0m\n\n1. Visit \u{1b}[36mhttps://auth.x.ai/activate\u{1b}[0m\n2. Enter this one-time code (expires in 10 minutes)\n   \u{1b}[1mK7Q2-9XPL\u{1b}[0m\n",
        "https://auth.x.ai/activate",
        "K7Q2-9XPL",
    ),
    (
        "Your device code is \"ABCD-1234\".\nGo to https://accounts.x.ai/oauth2/device?user_code=ABCD-1234 to approve.\n",
        "https://accounts.x.ai/oauth2/device?user_code=ABCD-1234",
        "ABCD-1234",
    ),
    (
        "Open https://accounts.x.ai/device?user_code=QRST-UVWX\nCode: QRST-UVWX (expires in 900s)\n",
        "https://accounts.x.ai/device?user_code=QRST-UVWX",
        "QRST-UVWX",
    ),
];

#[test]
fn grok_link_and_code_in_plausible_shapes() {
    for (text, url, code) in GROK_SHAPES {
        let got = offer(Agent::Grok, text).unwrap_or_else(|| panic!("an offer in {text:?}"));
        assert_eq!(got.url, *url, "{text:?}");
        assert_eq!(got.user_code.as_deref(), Some(*code), "{text:?}");
    }
    // Before the code's line is complete, nothing is offered.
    let (text, _, _) = GROK_SHAPES[0];
    let cut = &text[..text.rfind("WDJB-MJ").unwrap() + 7];
    assert_eq!(offer(Agent::Grok, cut), None);
    // A link with no code, or a code with no allowed link, is no offer.
    assert_eq!(offer(Agent::Grok, "Open https://accounts.x.ai/device to sign in.\n"), None);
    assert_eq!(offer(Agent::Grok, "Open https://evil.example/device\nCode: ABCD-1234\n"), None);
    // Words that only look like codes are not codes.
    assert_eq!(super::parse::grok_code("Enter the one-time code\nsee-you-soon\n"), None);
    assert_eq!(super::parse::grok_code("Enter the code\nAB-CD\n"), None);
    assert_eq!(super::parse::grok_code("Enter the code\nABCD1234\n"), None);
    assert_eq!(super::parse::grok_code("Your code ABCD-1234\n").as_deref(), Some("ABCD-1234"));
    // Gemini signs in with a key: its output is never an offer.
    assert_eq!(offer(Agent::Gemini, GROK_SHAPES[0].0), None);
}

#[test]
fn x_ai_sign_in_hosts_are_allowed() {
    assert!(allowed_url("https://accounts.x.ai/device").is_some());
    assert!(allowed_url("https://auth.x.ai/x").is_some());
    assert_eq!(allowed_url("https://x.ai.evil.example/device"), None);
    assert_eq!(allowed_url("https://evil.x.ai/device"), None);
}

#[test]
fn agents_by_name_and_what_each_signs_in_with() {
    for a in Agent::ALL {
        assert_eq!(Agent::parse(a.name()), Some(a));
    }
    assert_eq!(Agent::parse("opencode"), None);
    assert!(Agent::Cursor.signs_in_by_link() && !Agent::Cursor.takes_api_key());
    assert!(!Agent::Gemini.signs_in_by_link() && Agent::Gemini.takes_api_key());
    assert!(Agent::Grok.signs_in_by_link() && !Agent::Grok.takes_api_key());
    assert!(Agent::Claude.signs_in_by_link() && Agent::Codex.takes_api_key());
}

#[test]
fn gemini_and_grok_stores() {
    let mut cli = Cli::default();
    cli.env.insert("HOME".into(), "/tmp/u".into());
    assert_eq!(cli.store(Agent::Gemini), PathBuf::from("/tmp/u/.gemini"));
    assert_eq!(cli.store(Agent::Grok), PathBuf::from("/tmp/u/.grok"));
    cli.env.insert("GEMINI_CLI_HOME".into(), "/tmp/g".into());
    cli.env.insert("GROK_HOME".into(), "/tmp/x".into());
    // GEMINI_CLI_HOME stands for the home (`.gemini` under it); GROK_HOME is the store itself.
    assert_eq!(cli.store(Agent::Gemini), PathBuf::from("/tmp/g/.gemini"));
    assert_eq!(cli.store(Agent::Grok), PathBuf::from("/tmp/x"));
    let cmd = cli.command(&["login"], Path::new("/tmp"));
    let env: BTreeMap<_, _> = cmd.as_std().get_envs().collect();
    for (key, want) in [("GEMINI_CLI_HOME", "/tmp/g"), ("GROK_HOME", "/tmp/x")] {
        assert_eq!(
            env.get(std::ffi::OsStr::new(key)).copied().flatten(),
            Some(std::ffi::OsStr::new(want)),
            "{key}"
        );
    }
    for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "XAI_API_KEY"] {
        assert!(MODEL_PLANE_ENV.contains(&key), "{key}");
    }
}

#[test]
fn gemini_key_merges_into_dotenv_and_settings() {
    let store = dir("gemini");
    std::fs::write(
        store.join(".env"),
        "# mine\nGOOGLE_CLOUD_PROJECT=p1\nGEMINI_API_KEY=old\nexport GEMINI_API_KEY=\"older\"\nOTHER=x",
    )
    .unwrap();
    std::fs::write(
        store.join("settings.json"),
        r#"{"theme":"Dracula","security":{"folderTrust":{"enabled":false},"auth":{"selectedType":"oauth-personal","useExternal":false}}}"#,
    )
    .unwrap();
    merge_gemini_api_key(&store, "AIzaSyTest-key_1.2").unwrap();
    let env = std::fs::read_to_string(store.join(".env")).unwrap();
    assert_eq!(
        env,
        "# mine\nGOOGLE_CLOUD_PROJECT=p1\nOTHER=x\nGEMINI_API_KEY=AIzaSyTest-key_1.2\n"
    );
    let v: Value =
        serde_json::from_slice(&std::fs::read(store.join("settings.json")).unwrap()).unwrap();
    assert_eq!(v["theme"], "Dracula");
    assert_eq!(v["security"]["folderTrust"]["enabled"], false);
    assert_eq!(v["security"]["auth"]["selectedType"], "gemini-api-key");
    assert_eq!(v["security"]["auth"]["useExternal"], false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for name in [".env", "settings.json"] {
            let mode = std::fs::metadata(store.join(name)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600, "{name}");
        }
    }
    assert!(signed_in_at(Agent::Gemini, &store));
    // Saved again: still one key line.
    merge_gemini_api_key(&store, "AIzaNew").unwrap();
    let env = std::fs::read_to_string(store.join(".env")).unwrap();
    assert_eq!(env.matches("GEMINI_API_KEY").count(), 1, "{env}");
    assert!(env.ends_with("GEMINI_API_KEY=AIzaNew\n"));
    // No temp file is left beside them.
    let mut names: Vec<_> = std::fs::read_dir(&store)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, [".env", "settings.json"]);
    // A missing home is made.
    let fresh = store.join("fresh/.gemini");
    merge_gemini_api_key(&fresh, "AIzaX").unwrap();
    let v: Value =
        serde_json::from_slice(&std::fs::read(fresh.join("settings.json")).unwrap()).unwrap();
    assert_eq!(v, serde_json::json!({"security": {"auth": {"selectedType": "gemini-api-key"}}}));
    assert_eq!(std::fs::read_to_string(fresh.join(".env")).unwrap(), "GEMINI_API_KEY=AIzaX\n");
    // A settings file that is not an object (or whose security is not) is never replaced, and
    // then the key is not written either.
    for bad in ["[1]", "{not json", r#"{"security":"x"}"#, r#"{"security":{"auth":[]}}"#] {
        let s = dir("gemini-bad");
        std::fs::write(s.join("settings.json"), bad).unwrap();
        assert!(merge_gemini_api_key(&s, "AIzaY").is_err(), "{bad}");
        assert_eq!(std::fs::read_to_string(s.join("settings.json")).unwrap(), bad);
        assert!(!s.join(".env").exists(), "{bad}");
        let _ = std::fs::remove_dir_all(&s);
    }
    // A key a dotenv reader could split is refused.
    for bad in ["a b", "k#1", "k\"1", "k'1", "k=1", ""] {
        assert!(merge_gemini_api_key(&store, bad).is_err(), "{bad:?}");
    }
    let _ = std::fs::remove_dir_all(&store);
}

#[test]
fn gemini_and_grok_signed_in() {
    let store = dir("gg-stores");
    assert!(!signed_in_at(Agent::Gemini, &store));
    std::fs::write(store.join(".env"), "GEMINI_API_KEY=\nFOO=1\n").unwrap();
    assert!(!signed_in_at(Agent::Gemini, &store));
    std::fs::write(store.join(".env"), "GEMINI_API_KEY=\"\"\n").unwrap();
    assert!(!signed_in_at(Agent::Gemini, &store));
    std::fs::write(store.join(".env"), "export GEMINI_API_KEY='AIza'\n").unwrap();
    assert!(signed_in_at(Agent::Gemini, &store));
    std::fs::remove_file(store.join(".env")).unwrap();
    std::fs::write(store.join("oauth_creds.json"), "{}").unwrap();
    assert!(signed_in_at(Agent::Gemini, &store));
    assert!(!signed_in_at(Agent::Grok, &store));
    std::fs::write(store.join("auth.json"), " \n").unwrap();
    assert!(!signed_in_at(Agent::Grok, &store));
    std::fs::write(store.join("auth.json"), r#"{"x":1}"#).unwrap();
    assert!(signed_in_at(Agent::Grok, &store));
    let _ = std::fs::remove_dir_all(&store);
}

#[tokio::test]
async fn unsupported_ways_and_team_machines_for_gemini_and_grok() {
    let root = dir("gg-unsupported");
    let m = Machine { root: root.clone(), home: root.join("home") };
    let mut cli = Cli { program: root.join("no-such-cli").display().to_string(), ..Cli::default() };
    cli.env.insert("HOME".into(), root.join("home").display().to_string());
    let e = start(&m, &cli, Agent::Gemini).await.unwrap_err();
    assert_eq!(e.reason, reason::UNSUPPORTED);
    let e = save_api_key(&m, &cli, Agent::Grok, "xai-test-1234").await.unwrap_err();
    assert_eq!(e.reason, reason::UNSUPPORTED);
    // An owner machine saves the Gemini key with no CLI run.
    save_api_key(&m, &cli, Agent::Gemini, "AIzaOwner1").await.unwrap();
    assert!(signed_in_at(Agent::Gemini, &root.join("home/.gemini")));
    let e = save_api_key(&m, &cli, Agent::Gemini, "not a key").await.unwrap_err();
    assert_eq!(e.reason, reason::BAD_CODE);
    // A team machine: refused before anything runs or is written.
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/vm-kind"), "team\n").unwrap();
    let e = start(&m, &cli, Agent::Grok).await.unwrap_err();
    assert_eq!(e.reason, reason::SHARED_MACHINE);
    let e = save_api_key(&m, &cli, Agent::Gemini, "AIzaTeam2").await.unwrap_err();
    assert_eq!(e.reason, reason::SHARED_MACHINE);
    let env = std::fs::read_to_string(root.join("home/.gemini/.env")).unwrap();
    assert!(!env.contains("AIzaTeam2"));
    let _ = std::fs::remove_dir_all(&root);
}

/// `cursor-agent login` with `NO_OPEN_BROWSER=1` and plain pipes: one link to cursor.com, then
/// it waits for the approve (the shape of Cursor's CLI, 2026.11).
const CURSOR: &str = "\nCursor Agent\n\nTo log in, open this URL in your browser:\nhttps://cursor.com/loginDeepControl?challenge=abc_123&uuid=0f9c1e2d-1111-4222-8333-944455556666&mode=login\n\nWaiting for authentication...\n";

#[test]
fn cursor_link_only_on_cursor_hosts() {
    let got = offer(Agent::Cursor, CURSOR).expect("a link");
    assert!(
        got.url.starts_with("https://cursor.com/loginDeepControl?challenge=abc_123"),
        "{}",
        got.url
    );
    assert_eq!(got.user_code, None);
    // Each agent's link is on its own provider's hosts only.
    assert_eq!(offer(Agent::Claude, CURSOR), None);
    assert_eq!(offer(Agent::Codex, CURSOR), None);
    assert_eq!(offer(Agent::Cursor, CLAUDE_PLAIN), None);
    assert_eq!(offer(Agent::Cursor, "open https://cursor.com.evil.example/login \n"), None);
    assert_eq!(offer(Agent::Cursor, "open https://www.cursor.sh/login \n"), None);
    // A link still arriving is not offered.
    assert_eq!(offer(Agent::Cursor, "open this URL: https://cursor.com/loginDeepCon"), None);
    assert_eq!(allowed_url("https://cursor.com/loginDeepControl"), None);
}

#[test]
fn cursor_names_and_store() {
    assert_eq!(Agent::parse("cursor"), Some(Agent::Cursor));
    assert_eq!(Agent::Cursor.name(), "cursor");
    assert_eq!(Agent::Cursor.program(), "cursor-agent");
    assert_eq!(Agent::Codex.program(), "codex");
    let root = dir("cursor-store");
    let mut cli = Cli::default();
    cli.env.insert("HOME".into(), root.display().to_string());
    // An empty value is unset, whatever this test process's own XDG_CONFIG_HOME says.
    cli.env.insert("XDG_CONFIG_HOME".into(), String::new());
    assert_eq!(cli.store(Agent::Cursor), root.join(".config/cursor"));
    cli.env.insert("XDG_CONFIG_HOME".into(), root.join("xdg").display().to_string());
    assert_eq!(cli.store(Agent::Cursor), root.join("xdg/cursor"));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn cursor_signed_in_reads_its_auth_json() {
    let store = dir("cursor-auth");
    assert!(!signed_in_at(Agent::Cursor, &store));
    std::fs::write(store.join("auth.json"), "{}").unwrap();
    assert!(!signed_in_at(Agent::Cursor, &store));
    std::fs::write(store.join("auth.json"), r#"{"accessToken":""}"#).unwrap();
    assert!(!signed_in_at(Agent::Cursor, &store));
    std::fs::write(store.join("auth.json"), r#"{"accessToken":"t","refreshToken":"r"}"#).unwrap();
    assert!(signed_in_at(Agent::Cursor, &store));
    // Claude's and Codex's stores are not Cursor's.
    assert!(!signed_in_at(Agent::Claude, &store));
    let _ = std::fs::remove_dir_all(&store);
}

#[tokio::test]
async fn cursor_takes_no_key_here() {
    let root = dir("cursor-key");
    let m = Machine { root: root.clone(), home: root.join("home") };
    let cli = Cli { program: root.join("no-such-cli").display().to_string(), ..Cli::default() };
    let e = save_api_key(&m, &cli, Agent::Cursor, "key_0123456789").await.unwrap_err();
    assert_eq!(e.reason, reason::UNSUPPORTED_AGENT, "{e:?}");
    assert!(e.message.contains("CURSOR_API_KEY"), "{e:?}");
    let _ = std::fs::remove_dir_all(&root);
}

/// The whole sign-in against a stand-in `cursor-agent` (a fake of Cursor's login: it prints its
/// link, waits for the approve, writes `auth.json` and exits 0): `start` answers the link and no
/// code, `finish` waits for the approve and reads the sign-in from the store, the CLI saw no
/// Cursor key and no browser, and nothing it printed but the link reaches the answer.
#[cfg(unix)]
#[tokio::test]
async fn cursor_sign_in_end_to_end_against_a_stub_cli() {
    use std::os::unix::fs::PermissionsExt;
    let root = dir("cursor-e2e");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let approve = root.join("approve");
    let seen = root.join("seen-env");
    let program = root.join("cursor-agent");
    std::fs::write(
        &program,
        format!(
            "#!/bin/sh\n\
             [ \"$1\" = login ] || exit 9\n\
             env > {seen}\n\
             echo 'To log in, open this URL in your browser:'\n\
             echo 'https://cursor.com/loginDeepControl?challenge=stub&uuid=1&mode=login'\n\
             echo 'secret-looking-token-never-forwarded'\n\
             i=0; while [ ! -e {approve} ]; do i=$((i+1)); [ $i -gt 300 ] && exit 3; sleep 0.05; done\n\
             d=\"${{XDG_CONFIG_HOME:-$HOME/.config}}/cursor\"; mkdir -p \"$d\"\n\
             printf '{{\"accessToken\":\"a\",\"refreshToken\":\"r\"}}' > \"$d/auth.json\"\n",
            seen = seen.display(),
            approve = approve.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    let m = Machine { root: root.clone(), home: home.clone() };
    let mut cli = Cli { program: program.display().to_string(), ..Cli::default() };
    cli.env.insert("HOME".into(), home.display().to_string());
    cli.env.insert("XDG_CONFIG_HOME".into(), String::new());
    cli.env.insert("CURSOR_API_KEY".into(), "team-key-must-not-reach-the-login".into());
    let started = start(&m, &cli, Agent::Cursor).await.expect("started");
    assert_eq!(started.url, "https://cursor.com/loginDeepControl?challenge=stub&uuid=1&mode=login");
    assert_eq!(started.user_code, None);
    assert!(!started.needs_code);
    assert_eq!(started.auto_url, None);
    std::fs::write(&approve, "").unwrap();
    let finished = finish(&started.login_id, None).await.expect("finished");
    assert!(finished.signed_in);
    assert_eq!(finished.store, home.join(".config/cursor"));
    let env = std::fs::read_to_string(&seen).unwrap();
    assert!(!env.contains("CURSOR_API_KEY"), "the login saw a Cursor key");
    assert!(env.lines().any(|l| l == "NO_OPEN_BROWSER=1"), "{env}");
    assert!(env.lines().any(|l| l == "BROWSER=true"), "{env}");
    assert!(!env.lines().any(|l| l.starts_with("XDG_CONFIG_HOME=")), "{env}");
    let _ = std::fs::remove_dir_all(&root);
}
