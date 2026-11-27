use super::*;

fn dotenv_home(text: &str) -> (std::path::PathBuf, BTreeMap<String, String>) {
    let home = std::env::temp_dir().join(format!("acp-key-dotenv-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(home.join(".gemini")).unwrap();
    std::fs::write(home.join(".gemini/.env"), text).unwrap();
    let env = BTreeMap::from([("HOME".to_owned(), home.display().to_string())]);
    (home, env)
}

#[test]
fn antigravity_reads_the_saved_gemini_key() {
    let none = |_: &str| None;
    let (home, mut env) =
        dotenv_home("# saved by cmux\nOTHER=1\nexport GEMINI_API_KEY=\"AIza-own\"\n");
    fill_key_from_gemini_dotenv(&mut env, "antigravity", none);
    assert_eq!(env.get(GEMINI_API_KEY_ENV).map(String::as_str), Some("AIza-own"));

    // The launch's own key, the gateway's included, wins; so does the daemon's.
    let (_, mut gateway) = dotenv_home("GEMINI_API_KEY='AIza-own'\n");
    gateway.insert(GEMINI_API_KEY_ENV.to_owned(), "placeholder".to_owned());
    fill_key_from_gemini_dotenv(&mut gateway, "antigravity", none);
    assert_eq!(gateway[GEMINI_API_KEY_ENV], "placeholder");
    let (_, mut daemon) = dotenv_home("GEMINI_API_KEY=AIza-own\n");
    fill_key_from_gemini_dotenv(&mut daemon, "antigravity", |k| {
        (k == GEMINI_API_KEY_ENV).then(|| "daemon".to_owned())
    });
    assert!(!daemon.contains_key(GEMINI_API_KEY_ENV));

    // Other families, an empty value and no file leave the env alone.
    let (_, mut gemini) = dotenv_home("GEMINI_API_KEY=AIza-own\n");
    fill_key_from_gemini_dotenv(&mut gemini, "gemini", none);
    assert!(!gemini.contains_key(GEMINI_API_KEY_ENV));
    let (_, mut empty) = dotenv_home("GEMINI_API_KEY=\"\"\n");
    fill_key_from_gemini_dotenv(&mut empty, "antigravity", none);
    assert!(!empty.contains_key(GEMINI_API_KEY_ENV));
    std::fs::remove_file(home.join(".gemini/.env")).unwrap();
    fill_key_from_gemini_dotenv(&mut env, "antigravity", none);
    let mut gone = BTreeMap::from([("HOME".to_owned(), home.display().to_string())]);
    fill_key_from_gemini_dotenv(&mut gone, "antigravity", none);
    assert!(!gone.contains_key(GEMINI_API_KEY_ENV));
}

fn init(ids: &[&str]) -> Value {
    json!({"authMethods": ids.iter().map(|id| json!({"id": id, "name": id})).collect::<Vec<_>>()})
}

fn key(v: Option<&str>) -> impl Fn(&str) -> Option<String> {
    let v = v.map(str::to_owned);
    move |name| (name == GEMINI_API_KEY_ENV).then(|| v.clone()).flatten()
}

#[test]
fn a_key_and_the_method_authenticate() {
    let params = authenticate_params(
        "antigravity",
        &init(&["oauth-personal", "gemini-api-key"]),
        key(Some("k")),
    );
    assert_eq!(params, Some(json!({"methodId": "gemini-api-key"})));
}

#[test]
fn no_key_or_no_method_asks_nothing() {
    assert_eq!(authenticate_params("antigravity", &init(&["gemini-api-key"]), key(None)), None);
    assert_eq!(
        authenticate_params("antigravity", &init(&["gemini-api-key"]), key(Some("  "))),
        None
    );
    assert_eq!(
        authenticate_params("antigravity", &init(&["oauth-personal"]), key(Some("k"))),
        None
    );
    assert_eq!(authenticate_params("antigravity", &json!({}), key(Some("k"))), None);
}

#[test]
fn gemini_cli_reads_its_key_itself() {
    assert_eq!(authenticate_params("gemini", &init(&["gemini-api-key"]), key(Some("k"))), None);
}

#[test]
fn the_profile_env_wins_over_the_daemon() {
    let mut env = BTreeMap::new();
    env.insert("ACPMUX_KEY_AUTH_TEST_VAR".to_owned(), "from-profile".to_owned());
    assert_eq!(
        launch_var(&env, "antigravity", "ACPMUX_KEY_AUTH_TEST_VAR").as_deref(),
        Some("from-profile")
    );
}
