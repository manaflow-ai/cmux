use super::*;

fn acp(argv: &[&str], env: &[(&str, &str)]) -> HarnessProfile {
    HarnessProfile {
        kind: HarnessKind::Acp,
        argv: argv.iter().map(|s| s.to_string()).collect(),
        env: env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

fn config(profile: HarnessProfile) -> Config {
    let mut cfg = Config::default();
    cfg.harnesses.insert("codex".into(), profile);
    cfg
}

/// The commands a login ran in the terminal (each exits 0).
async fn ran(cfg: &Config, method: Option<&str>) -> (Result<String>, Vec<Vec<String>>) {
    let ran = std::sync::Mutex::new(Vec::new());
    let terminal = |argv: &[String], _: &BTreeMap<String, String>| {
        ran.lock().unwrap().push(argv.to_vec());
        Ok(0)
    };
    let outcome = login(cfg, "codex", method, Duration::from_secs(5), &terminal).await;
    (outcome, ran.into_inner().unwrap())
}

/// The commands and envs a login ran in the terminal (each exits 0).
async fn ran_with_env(cfg: &Config) -> Vec<(Vec<String>, BTreeMap<String, String>)> {
    let ran = std::sync::Mutex::new(Vec::new());
    let terminal = |argv: &[String], env: &BTreeMap<String, String>| {
        ran.lock().unwrap().push((argv.to_vec(), env.clone()));
        Ok(0)
    };
    login(cfg, "codex", None, Duration::from_secs(5), &terminal).await.unwrap();
    ran.into_inner().unwrap()
}

/// A fake `codex` that answers `out` and exits `code` only when it is run
/// as `codex <args>` with `CODEX_HOME=<home>`; any other command exits 2
/// with output that is not Codex's "Not logged in".
#[cfg(unix)]
fn fake_codex(test: &str, args: &str, home: &str, out: &str, code: i32) -> String {
    let dir = std::env::temp_dir().join(format!("acpmux-login-{test}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("codex");
    let script = format!(
        "#!/bin/sh\n\
             if [ \"$*\" != '{args}' ] || [ \"${{CODEX_HOME-}}\" != '{home}' ]; then\n\
             echo \"unexpected: $* (CODEX_HOME=${{CODEX_HOME-}})\"; exit 2\nfi\n\
             echo '{out}'\nexit {code}\n"
    );
    crate::test_exec::write_executable(&path, script);
    path.to_string_lossy().into_owned()
}

#[tokio::test]
async fn codex_bridge_login_runs_codex_login_in_this_terminal() {
    let (outcome, ran) = ran(&config(acp(&["/opt/bin/codex", "app-server"], &[])), None).await;
    assert_eq!(outcome.unwrap(), "codex: signed in");
    assert_eq!(ran, vec![vec!["/opt/bin/codex".to_owned(), "login".to_owned()]]);
}

#[tokio::test]
async fn codex_bridge_login_runs_the_codex_path_binary_like_the_launch() {
    let profile = acp(&["codex", "app-server"], &[("CODEX_PATH", "/opt/codex-new")]);
    let (outcome, ran) = ran(&config(profile), None).await;
    assert_eq!(outcome.unwrap(), "codex: signed in");
    assert_eq!(ran, vec![vec!["/opt/codex-new".to_owned(), "login".to_owned()]]);
}

#[tokio::test]
async fn codex_bridge_login_takes_codex_path_from_the_family_defaults() {
    let mut cfg = config(acp(&["codex", "app-server"], &[]));
    let mut defaults = crate::config::SessionDefaults::default();
    defaults.env.insert("CODEX_PATH".into(), "/opt/codex-family".into());
    cfg.defaults.insert("codex".into(), defaults);
    let (outcome, ran) = ran(&cfg, None).await;
    assert_eq!(outcome.unwrap(), "codex: signed in");
    assert_eq!(ran, vec![vec!["/opt/codex-family".to_owned(), "login".to_owned()]]);
}

#[tokio::test]
async fn codex_bridge_login_refuses_an_acp_method() {
    let (outcome, ran) =
        ran(&config(acp(&["/opt/bin/codex", "app-server"], &[])), Some("chatgpt")).await;
    let err = outcome.unwrap_err().to_string();
    assert!(err.contains("codex login"), "{err}");
    assert!(ran.is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn codex_bridge_status_asks_codex_login_status() {
    let timeout = Duration::from_secs(5);
    let home = [("CODEX_HOME", "/tmp/acpmux-login-codex-home")];
    let codex = |test, out, code| {
        fake_codex(test, "login status", "/tmp/acpmux-login-codex-home", out, code)
    };
    let signed_in = config(acp(&[&codex("in", "Logged in using ChatGPT", 0), "app-server"], &home));
    assert_eq!(
        auth_state(&signed_in, "codex", timeout).await.unwrap(),
        AuthState::SignedIn { methods: vec![] }
    );
    let signed_out = config(acp(&[&codex("out", "Not logged in", 1), "app-server"], &home));
    assert!(matches!(
        auth_state(&signed_out, "codex", timeout).await.unwrap(),
        AuthState::Required { .. }
    ));
    // A failure that is not Codex's own "Not logged in" says nothing about a sign-in.
    let broken = config(acp(&[&codex("err", "Error loading config.toml", 1), "app-server"], &home));
    assert!(auth_state(&broken, "codex", timeout).await.is_err());
    // The fake answers nothing but `login status` with that CODEX_HOME.
    let wrong_home = config(acp(&[&codex("home", "Logged in", 0), "app-server"], &[]));
    assert!(auth_state(&wrong_home, "codex", timeout).await.is_err());
}

#[cfg(unix)]
#[tokio::test]
async fn codex_bridge_status_keeps_the_launch_global_options() {
    let store = "cli_auth_credentials_store=\"keyring\"";
    let codex = fake_codex(
        "globals",
        &format!("-c {store} --profile=work login status"),
        "/tmp/acpmux-login-codex-home",
        "Logged in using ChatGPT",
        0,
    );
    let cfg = config(acp(
        &[&codex, "-c", store, "--profile=work", "app-server", "--listen", "stdio://"],
        &[("CODEX_HOME", "/tmp/acpmux-login-codex-home")],
    ));
    assert_eq!(
        auth_state(&cfg, "codex", Duration::from_secs(5)).await.unwrap(),
        AuthState::SignedIn { methods: vec![] }
    );
}

#[tokio::test]
async fn codex_bridge_login_keeps_the_launch_global_options() {
    let cfg = config(acp(
        &["/opt/bin/codex", "--enable", "x", "-c", "k=v", "--profile=work", "app-server"],
        &[],
    ));
    let (outcome, ran) = ran(&cfg, None).await;
    assert_eq!(outcome.unwrap(), "codex: signed in");
    let want = ["/opt/bin/codex", "--enable", "x", "-c", "k=v", "--profile=work", "login"];
    assert_eq!(ran, vec![want.map(String::from).to_vec()]);
}

#[tokio::test]
async fn codex_bridge_login_expands_paths_like_the_launch() {
    let home = dirs::home_dir().unwrap_or_default().to_string_lossy().into_owned();
    let mut cfg = config(acp(&["codex", "app-server"], &[("CODEX_HOME", "~/.codex-work")]));
    let mut defaults = crate::config::SessionDefaults::default();
    defaults.env.insert("CODEX_PATH".into(), "${home}/bin/codex".into());
    cfg.defaults.insert("codex".into(), defaults);
    let ran = ran_with_env(&cfg).await;
    assert_eq!(ran.len(), 1);
    let (argv, env) = &ran[0];
    assert_eq!(argv, &vec![format!("{home}/bin/codex"), "login".to_owned()]);
    assert_eq!(env.get("CODEX_HOME"), Some(&format!("{home}/.codex-work")));
    assert_eq!(env.get("CODEX_PATH"), Some(&format!("{home}/bin/codex")));
}

/// A `${file:…}` reference reads the path after `${home}` is expanded,
/// as the launch does (`hub::spawn` expands, `agent::command` resolves).
#[cfg(unix)]
#[test]
fn codex_bridge_expands_paths_before_reading_references() {
    use std::os::unix::fs::PermissionsExt;
    let home = std::env::temp_dir().join(format!("acpmux-login-refs-{}", std::process::id()));
    std::fs::create_dir_all(home.join(".secrets")).unwrap();
    let key = home.join(".secrets/openai");
    std::fs::write(&key, "sk-test\n").unwrap();
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
    let cfg = config(acp(
        &["codex", "app-server"],
        &[("OPENAI_API_KEY", "${file:${home}/.secrets/openai}")],
    ));
    let codex =
        codex_cli_at(&cfg, "codex", &cfg.harnesses["codex"], std::path::Path::new("/"), &home)
            .unwrap();
    assert_eq!(codex.env.get("OPENAI_API_KEY").map(String::as_str), Some("sk-test"));
    std::fs::remove_dir_all(&home).unwrap();
}

#[test]
fn codex_globals_stop_at_app_server() {
    let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert!(codex_globals(&args(&["app-server"])).is_empty());
    assert_eq!(
        codex_globals(&args(&["-c", "a=b", "--enable=x", "-p", "w", "app-server", "--x"])),
        &args(&["-c", "a=b", "--enable=x", "-p", "w"])[..]
    );
}
