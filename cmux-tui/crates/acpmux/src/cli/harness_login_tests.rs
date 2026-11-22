//! `cmux harness login` against the fake ACP agent (tests/fake_agent.py with
//! FAKE_AUTH_FILE: session/new answers -32000 until the file exists).

use super::*;
use std::sync::Mutex;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn fake(name: &str) -> (Config, std::path::PathBuf) {
    let file = std::env::temp_dir().join(format!("acpmux-login-{name}-{}", std::process::id()));
    let _ = std::fs::remove_file(&file);
    let mut cfg = Config::default();
    cfg.harnesses.insert(
        "fake".into(),
        HarnessProfile {
            kind: HarnessKind::Acp,
            argv: vec!["python3".into(), FAKE.into()],
            env: BTreeMap::from([(
                "FAKE_AUTH_FILE".to_owned(),
                file.to_string_lossy().into_owned(),
            )]),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    (cfg, file)
}

const T: Duration = Duration::from_secs(30);

fn no_terminal(_: &[String], _: &BTreeMap<String, String>) -> Result<i32> {
    panic!("this sign-in must not run a terminal command");
}

#[tokio::test(flavor = "multi_thread")]
async fn status_reports_required_then_an_agent_login_signs_in() {
    let (cfg, file) = fake("agent");
    let state = auth_state(&cfg, "fake", T).await.unwrap();
    let AuthState::Required { methods, message } = state else { panic!("{state:?}") };
    assert!(message.contains("Authentication required"), "{message}");
    let ids: Vec<&str> = methods.iter().map(|m| m.id.as_str()).collect();
    // An unknown method type is left out.
    assert_eq!(ids, ["fake-login", "fake-terminal", "fake-key"]);
    assert_eq!(methods[1].kind, "terminal");
    assert_eq!(methods[2].var_name.as_deref(), Some("FAKE_API_KEY"));
    let done = login(&cfg, "fake", None, T, &no_terminal).await.unwrap();
    assert_eq!(done, "fake: signed in with Fake login");
    assert!(matches!(auth_state(&cfg, "fake", T).await.unwrap(), AuthState::SignedIn { .. }));
    let _ = std::fs::remove_file(&file);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_terminal_login_runs_the_harness_program_with_the_method_s_arguments() {
    let (cfg, file) = fake("terminal");
    let ran: Mutex<Vec<String>> = Mutex::new(vec![]);
    let runner = |argv: &[String], env: &BTreeMap<String, String>| -> Result<i32> {
        *ran.lock().unwrap() = argv.to_vec();
        run_in_this_terminal(argv, env)
    };
    let done = login(&cfg, "fake", Some("fake-terminal"), T, &runner).await.unwrap();
    assert_eq!(done, "fake: signed in with Terminal login");
    assert_eq!(
        *ran.lock().unwrap(),
        vec!["python3".to_owned(), FAKE.into(), "--fake-login".into()]
    );
    let _ = std::fs::remove_file(&file);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_api_key_method_says_how_to_store_the_key_and_unknown_methods_are_named() {
    let (cfg, file) = fake("key");
    let done = login(&cfg, "fake", Some("fake-key"), T, &no_terminal).await.unwrap();
    assert!(done.contains("cmux harness secret set fake FAKE_API_KEY"), "{done}");
    let err = login(&cfg, "fake", Some("nope"), T, &no_terminal).await.unwrap_err().to_string();
    assert!(err.contains("fake-login, fake-terminal, fake-key"), "{err}");
    assert!(!file.exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn claude_code_signs_in_with_claude_auth_login() {
    let mut cfg = Config::default();
    let mut profile = fake("claude").0.harnesses["fake"].clone();
    profile.kind = HarnessKind::ClaudeStdio;
    profile.argv = vec!["/u/bin/claude".into()];
    cfg.harnesses.insert("claude".into(), profile);
    let ran: Mutex<Vec<String>> = Mutex::new(vec![]);
    let runner = |argv: &[String], _: &BTreeMap<String, String>| -> Result<i32> {
        *ran.lock().unwrap() = argv.to_vec();
        Ok(0)
    };
    assert_eq!(login(&cfg, "claude", None, T, &runner).await.unwrap(), "claude: signed in");
    assert_eq!(
        *ran.lock().unwrap(),
        vec!["/u/bin/claude".to_owned(), "auth".into(), "login".into()]
    );
    assert!(matches!(auth_state(&cfg, "claude", T).await.unwrap(), AuthState::NotAcp { .. }));
}

#[test]
fn the_profile_env_wins_over_a_method_s_and_loader_keys_never_come_from_the_agent() {
    let profile = BTreeMap::from([("TOKEN".to_owned(), "mine".to_owned())]);
    let method = BTreeMap::from([
        ("TOKEN".to_owned(), "theirs".to_owned()),
        ("PATH".to_owned(), "/evil".to_owned()),
        ("DYLD_INSERT_LIBRARIES".to_owned(), "/x".to_owned()),
        ("LOGIN_MODE".to_owned(), "device".to_owned()),
    ]);
    let env = method_env(&profile, &method);
    assert_eq!(env.get("TOKEN").map(String::as_str), Some("mine"));
    assert_eq!(env.get("LOGIN_MODE").map(String::as_str), Some("device"));
    assert!(!env.contains_key("PATH") && !env.contains_key("DYLD_INSERT_LIBRARIES"));
}
