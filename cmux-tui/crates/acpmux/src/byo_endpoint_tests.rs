//! Your own model endpoint as a harness (u2586): the profile `add` writes for
//! `anthropic-endpoint` and `openai-endpoint`, the URL and secret checks,
//! the Keychain write, the spawn env, and the doctor's real hello turn
//! against a local fake endpoint.

use super::*;
use crate::cli::harness::{DoctorOptions, DoctorReport, Step, StepStatus, doctor};
use crate::cli::harness_secret::StoreCommand;
use crate::config::profiles::{self, ProfileMeta, ProfileSources};
use crate::config::{Config, HarnessKind, HarnessProfile, ProfileSource};
use crate::harness_admin::{self as admin, AddParams, AdminError};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_endpoint_claude.py");
const GOOD_KEY: &str = "sk-byo-good-7f3a9c2e1b";
const BAD_KEY: &str = "sk-byo-bad-4d8e6f0a2c";

fn scratch(name: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-byo-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::canonicalize(&dir).unwrap()
}

fn sources(root: &Path) -> ProfileSources {
    ProfileSources { user_dir: Some(root.join("harnesses")), ..ProfileSources::none() }
}

fn params(example: &str, id: &str, url: &str, model: &str, item: Option<&str>) -> AddParams {
    AddParams {
        id: Some(id.into()),
        example: Some(example.into()),
        base_url: Some(url.into()),
        model: Some(model.into()),
        keychain_item: item.map(str::to_owned),
        ..Default::default()
    }
}

fn add(p: &AddParams, sources: &ProfileSources) -> Result<admin::Added, AdminError> {
    admin::add(p, sources, None, &|_| None)
}

fn load(path: &Path, id: &str) -> (HarnessProfile, ProfileMeta) {
    let text = std::fs::read_to_string(path).unwrap();
    match profiles::parse_profile_toml(&text, path, Some(id), ProfileSource::UserFile) {
        Ok((_, profile, meta, warnings)) => {
            assert!(warnings.is_empty(), "{warnings:?}\n{text}");
            (profile, meta)
        }
        Err(errors) => panic!("{errors:?}\n{text}"),
    }
}

fn config(id: &str, profile: HarnessProfile, meta: ProfileMeta) -> Config {
    let mut cfg = Config::default();
    cfg.harnesses.insert(id.into(), profile);
    cfg.profile_meta.insert(id.into(), meta);
    cfg
}

#[test]
fn byo_endpoint_anthropic_profile_runs_claude_with_a_keychain_token() {
    let root = scratch("anthropic");
    let src = sources(&root);
    let mut p = params(
        "anthropic-endpoint",
        "acme-claude",
        "https://llm.example.com/anthropic/",
        "acme-large",
        Some("acme/anthropic"),
    );
    p.display_name = Some("Acme Large".into());
    let added = add(&p, &src).unwrap();
    assert_eq!(added.path, root.join("harnesses").join("acme-claude.toml"));
    assert!(added.diagnostics.is_empty(), "{:?}", added.diagnostics);
    let reply = serde_json::to_value(&added).unwrap();
    assert_eq!(reply["secret"]["key"], "ANTHROPIC_AUTH_TOKEN", "{reply}");
    assert_eq!(reply["secret"]["keychainItem"], "acme/anthropic", "{reply}");

    let (profile, meta) = load(&added.path, "acme-claude");
    assert_eq!(profile.kind, HarnessKind::ClaudeStdio);
    assert_eq!(profile.argv, vec!["claude".to_owned()]);
    assert_eq!(profile.model.as_deref(), Some("acme-large"));
    assert_eq!(meta.display_name.as_deref(), Some("Acme Large"));
    let env = &profile.env;
    assert_eq!(env["ANTHROPIC_BASE_URL"], "https://llm.example.com/anthropic");
    assert_eq!(env["ANTHROPIC_AUTH_TOKEN"], "${keychain:acme/anthropic}");
    for key in ["ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"] {
        assert_eq!(env[key], "acme-large", "{key}");
    }
    assert_eq!(Kind::of_env(env), Some(Kind::Anthropic));

    // Without keychainItem: the item `cmux harness secret set ID KEY` writes.
    let added =
        add(&params("anthropic-endpoint", "dflt", "https://llm.example.com", "m1", None), &src)
            .unwrap();
    let (profile, _) = load(&added.path, "dflt");
    let item = crate::cli::harness_secret::reference("dflt", "ANTHROPIC_AUTH_TOKEN");
    assert_eq!(profile.env["ANTHROPIC_AUTH_TOKEN"], format!("${{keychain:{item}}}"));
    let reply = serde_json::to_value(&added).unwrap();
    assert_eq!(reply["secret"]["keychainItem"], json!(item), "{reply}");
}

#[test]
fn byo_endpoint_openai_profile_configures_opencode_with_a_keychain_key() {
    let root = scratch("openai");
    let src = sources(&root);
    let added = add(
        &params("openai-endpoint", "acme-oai", "https://api.example.com/v1/", "org/model-7b", None),
        &src,
    )
    .unwrap();
    assert!(added.diagnostics.is_empty(), "{:?}", added.diagnostics);
    let reply = serde_json::to_value(&added).unwrap();
    assert_eq!(reply["secret"]["key"], OPENAI_KEY_ENV, "{reply}");

    let (profile, _) = load(&added.path, "acme-oai");
    assert_eq!(profile.kind, HarnessKind::Acp);
    assert_eq!(profile.argv, vec!["opencode".to_owned(), "acp".to_owned()]);
    assert_eq!(profile.model.as_deref(), Some("byo/org/model-7b"));
    let item = crate::cli::harness_secret::reference("acme-oai", OPENAI_KEY_ENV);
    assert_eq!(profile.env[OPENAI_KEY_ENV], format!("${{keychain:{item}}}"));
    assert_eq!(Kind::of_env(&profile.env), Some(Kind::OpenAi));
    let config: Value = serde_json::from_str(&profile.env["OPENCODE_CONFIG_CONTENT"]).unwrap();
    let provider = &config["provider"]["byo"];
    assert_eq!(provider["npm"], "@ai-sdk/openai-compatible", "{config}");
    assert_eq!(provider["options"]["baseURL"], "https://api.example.com/v1", "{config}");
    assert_eq!(provider["options"]["apiKey"], format!("{{env:{OPENAI_KEY_ENV}}}"), "{config}");
    assert!(provider["models"]["org/model-7b"].is_object(), "{config}");
    assert_eq!(config["model"], "byo/org/model-7b", "{config}");
}

#[test]
fn byo_endpoint_add_checks_the_url_and_refuses_a_literal_key() {
    let root = scratch("checks");
    let src = sources(&root);
    let try_url = |url: &str| add(&params("anthropic-endpoint", "u", url, "m", None), &src);
    for ok in [
        "https://llm.example.com",
        "http://localhost:8080/v1",
        "http://127.0.0.1:9/x",
        "http://[::1]:8080",
    ] {
        let mut p = params("anthropic-endpoint", "u", ok, "m", None);
        p.replace = true;
        add(&p, &src).unwrap_or_else(|e| panic!("{ok}: {e}"));
    }
    std::fs::remove_file(root.join("harnesses").join("u.toml")).unwrap();
    for bad in [
        "http://llm.example.com",
        "ftp://llm.example.com",
        "llm.example.com",
        "https://",
        "https://llm.example.com/v1#frag",
        "https://llm.example.com/${HOME}",
    ] {
        match try_url(bad) {
            Err(AdminError::Invalid(m)) => assert!(!m.is_empty()),
            other => panic!("{bad}: {other:?}"),
        }
    }
    // A key in the URL is a literal key.
    for secret in
        ["https://me:hunter2pass@llm.example.com", "https://llm.example.com/v1?api_key=abc123"]
    {
        match try_url(secret) {
            Err(e @ AdminError::SecretInline(_)) => {
                assert_eq!(e.reason(), Some("harness.secret_inline"));
                assert!(!e.message().contains("hunter2pass") && !e.message().contains("abc123"));
            }
            other => panic!("{secret}: {other:?}"),
        }
    }
    // A key where the Keychain item name goes.
    let p = params("anthropic-endpoint", "u", "https://x.example.com", "m", Some(GOOD_KEY));
    match add(&p, &src) {
        Err(e @ AdminError::SecretInline(_)) => assert!(!e.message().contains(GOOD_KEY)),
        other => panic!("{other:?}"),
    }
    // The key itself, as a parameter.
    for name in ["key", "apiKey", "token", "value"] {
        let params = json!({"example": "openai-endpoint", "id": "u", "baseUrl": "https://x.example.com",
            "model": "m", name: GOOD_KEY});
        match AddParams::from_json(&params) {
            Err(e @ AdminError::SecretInline(_)) => assert!(!e.message().contains(GOOD_KEY)),
            other => panic!("{name}: {other:?}"),
        }
    }
    // Model and base URL are required; they go only with an endpoint example.
    let mut p = params("openai-endpoint", "u", "https://x.example.com", "m", None);
    p.model = None;
    assert!(matches!(add(&p, &src), Err(AdminError::Invalid(_))));
    let mut p = params("openai-endpoint", "u", "https://x.example.com", "m", None);
    p.base_url = None;
    assert!(matches!(add(&p, &src), Err(AdminError::Invalid(_))));
    for model in ["two words", "{file:/etc/passwd}", "a\"b"] {
        let p = params("openai-endpoint", "u", "https://x.example.com", model, None);
        assert!(matches!(add(&p, &src), Err(AdminError::Invalid(_))), "{model}");
    }
    let p = params("codex", "u", "https://x.example.com", "m", None);
    assert!(matches!(add(&p, &src), Err(AdminError::Invalid(_))));
    // Nothing was written by a refused add.
    assert!(!root.join("harnesses").join("u.toml").exists());
}

#[test]
fn byo_endpoint_classify_names_the_fix() {
    let cases = [
        (
            r#"API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#,
            Problem::Key,
        ),
        ("Incorrect API key provided: sk-...", Problem::Key),
        ("AI_APICallError: Unauthorized", Problem::Key),
        (
            r#"API Error: 404 {"type":"error","error":{"type":"not_found_error","message":"model: acme-huge"}}"#,
            Problem::Model,
        ),
        ("The model `gpt-9` does not exist or you do not have access to it.", Problem::Model),
        (
            "API Error: Connection error. (<urlopen error [Errno 61] Connection refused>)",
            Problem::BaseUrl,
        ),
        ("getaddrinfo ENOTFOUND llm.example.invalid", Problem::BaseUrl),
        ("API Error: 404 Not Found", Problem::BaseUrl),
        ("listening on port 4011", Problem::Other),
        ("something odd happened", Problem::Other),
    ];
    for (text, want) in cases {
        assert_eq!(classify(text), want, "{text}");
    }
    let key = fix(Problem::Key, Kind::Anthropic, "acme");
    assert!(key.contains("check the key"), "{key}");
    assert!(key.contains("cmux harness secret set acme ANTHROPIC_AUTH_TOKEN"), "{key}");
    let key = fix(Problem::Key, Kind::OpenAi, "acme");
    assert!(key.contains(&format!("cmux harness secret set acme {OPENAI_KEY_ENV}")), "{key}");
    assert!(fix(Problem::BaseUrl, Kind::Anthropic, "acme").contains("check the base URL"));
    assert!(fix(Problem::Model, Kind::OpenAi, "acme").contains("model not found"));
}

#[tokio::test(flavor = "multi_thread")]
async fn byo_endpoint_spawn_drops_inherited_provider_env() {
    let root = scratch("spawn");
    let added = add(
        &params("anthropic-endpoint", "spawn", "https://llm.example.com", "m1", None),
        &sources(&root),
    )
    .unwrap();
    let (mut profile, _) = load(&added.path, "spawn");
    // A resolved value stands in for the Keychain item (no Keychain in tests).
    profile.env.insert("ANTHROPIC_AUTH_TOKEN".into(), "resolved-token".into());
    let cmd = crate::agent::harness_command(
        "spawn",
        &profile,
        &root,
        Some(("claude".into(), vec!["-p".into(), "hi".into()])),
        None,
    )
    .unwrap();
    let envs: Vec<(String, Option<String>)> = cmd
        .as_std()
        .get_envs()
        .map(|(k, v)| {
            (k.to_string_lossy().into_owned(), v.map(|v| v.to_string_lossy().into_owned()))
        })
        .collect();
    let get = |key: &str| envs.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
    for key in [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_CUSTOM_HEADERS",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
    ] {
        assert_eq!(get(key), Some(None), "{key} must be removed: {envs:?}");
    }
    assert_eq!(get("ANTHROPIC_BASE_URL"), Some(Some("https://llm.example.com".into())));
    assert_eq!(get("ANTHROPIC_AUTH_TOKEN"), Some(Some("resolved-token".into())));
    assert!(!matches!(get(OWN_ENDPOINT_KEY), Some(Some(_))), "the marker reached the harness");
}

#[test]
fn byo_endpoint_secret_set_stores_through_stdin_and_never_echoes() {
    let root = scratch("secret");
    let added = add(
        &params("anthropic-endpoint", "sec", "https://llm.example.com", "m1", Some("old/item")),
        &sources(&root),
    )
    .unwrap();
    let (profile, meta) = load(&added.path, "sec");
    let cfg = config("sec", profile, meta);
    let seen = std::sync::Mutex::new(Vec::<(Vec<String>, String)>::new());
    let store = |c: &StoreCommand| -> anyhow::Result<()> {
        seen.lock().unwrap().push((c.argv.clone(), c.stdin.to_string()));
        Ok(())
    };
    let done = admin::secret_set("sec", "ANTHROPIC_AUTH_TOKEN", GOOD_KEY, &cfg, &store).unwrap();
    let reply = serde_json::to_string(&done).unwrap();
    assert!(!reply.contains(GOOD_KEY), "{reply}");
    let item = crate::cli::harness_secret::reference("sec", "ANTHROPIC_AUTH_TOKEN");
    let reply: Value = serde_json::from_str(&reply).unwrap();
    assert_eq!(reply["keychainItem"], json!(item), "{reply}");
    assert_eq!(reply["profile"], "written", "{reply}");
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert!(seen[0].0.iter().all(|a| !a.contains(GOOD_KEY)), "the value is in argv");
        assert!(seen[0].1.contains(GOOD_KEY), "the value goes on stdin");
    }
    let text = std::fs::read_to_string(&added.path).unwrap();
    assert!(!text.contains(GOOD_KEY));
    let (profile, _) = load(&added.path, "sec");
    assert_eq!(profile.env["ANTHROPIC_AUTH_TOKEN"], format!("${{keychain:{item}}}"));

    // An unknown harness stores nothing.
    let e = admin::secret_set("nope", "ANTHROPIC_AUTH_TOKEN", GOOD_KEY, &cfg, &store).unwrap_err();
    assert_eq!(e.reason(), Some("harness.not_found"), "{e}");
    assert_eq!(seen.lock().unwrap().len(), 1);
    // A failing store names no value.
    let failing = |_: &StoreCommand| -> anyhow::Result<()> { anyhow::bail!("security failed") };
    let e = admin::secret_set("sec", "ANTHROPIC_AUTH_TOKEN", GOOD_KEY, &cfg, &failing).unwrap_err();
    assert!(!e.message().contains(GOOD_KEY), "{e}");
}

// ------------------------------------------------- doctor's hello turn

/// A one-thread fake Anthropic Messages API on 127.0.0.1: 200 with "OK" for
/// `Bearer GOOD_KEY` and model `good-model`, else Anthropic's 401 or 404.
fn fake_endpoint(hits: Arc<AtomicUsize>) -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            hits.fetch_add(1, Ordering::SeqCst);
            let _ = answer(stream);
        }
    });
    port
}

fn answer(stream: std::net::TcpStream) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let path = line.split_whitespace().nth(1).unwrap_or("").to_owned();
    let (mut length, mut auth) = (0usize, String::new());
    loop {
        let mut header = String::new();
        reader.read_line(&mut header)?;
        let header = header.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':') {
            match name.trim().to_ascii_lowercase().as_str() {
                "content-length" => length = value.trim().parse().unwrap_or(0),
                "authorization" => auth = value.trim().to_owned(),
                _ => {}
            }
        }
    }
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body)?;
    let request: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let (status, reply) = if path != "/v1/messages" {
        ("404 Not Found", "Not Found".to_owned())
    } else if auth != format!("Bearer {GOOD_KEY}") {
        (
            "401 Unauthorized",
            json!({"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}).to_string(),
        )
    } else if request["model"] != "good-model" {
        (
            "404 Not Found",
            json!({"type": "error", "error": {"type": "not_found_error", "message": format!("model: {}", request["model"])}}).to_string(),
        )
    } else {
        (
            "200 OK",
            json!({"id": "msg_1", "type": "message", "role": "assistant", "model": "good-model",
                "content": [{"type": "text", "text": "OK"}], "stop_reason": "end_turn",
                "usage": {"input_tokens": 5, "output_tokens": 1}})
            .to_string(),
        )
    };
    let mut stream = stream;
    write!(
        stream,
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
        reply.len()
    )?;
    stream.flush()
}

/// The fake `claude`, copied executable into `root`.
fn fake_claude(root: &Path) -> PathBuf {
    let path = root.join("claude");
    crate::test_exec::write_executable(&path, std::fs::read(FAKE_CLAUDE).unwrap());
    path
}

/// A config with one endpoint harness `byo` on the fake claude.
fn endpoint_config(root: &Path, url: &str, model: &str) -> Config {
    let mut p = params("anthropic-endpoint", "byo", url, model, Some("byo-test/key"));
    p.replace = true;
    let added = add(&p, &sources(root)).unwrap();
    let (mut profile, meta) = load(&added.path, "byo");
    profile.argv[0] = fake_claude(root).to_string_lossy().into_owned();
    config("byo", profile, meta)
}

fn options(key: &'static str, prompt: bool) -> DoctorOptions {
    DoctorOptions {
        folder: None,
        prompt,
        timeout: Duration::from_secs(30),
        lookup_env: Box::new(|_| None),
        lookup_keychain: Box::new(move |service, account| match (service, account) {
            ("byo-test", Some("key")) => Ok(key.to_owned()),
            _ => Err("not found".into()),
        }),
    }
}

fn step<'a>(report: &'a DoctorReport, name: &str) -> &'a Step {
    report
        .steps
        .iter()
        .find(|s| s.step == name)
        .unwrap_or_else(|| panic!("no step {name}: {}", report.text()))
}

#[tokio::test(flavor = "multi_thread")]
async fn byo_endpoint_doctor_runs_a_real_turn_and_names_the_fix() {
    let root = scratch("doctor");
    let hits = Arc::new(AtomicUsize::new(0));
    let port = fake_endpoint(hits.clone());
    let url = format!("http://127.0.0.1:{port}");

    // The right key and model: the turn answers.
    let cfg = endpoint_config(&root, &url, "good-model");
    let report = doctor(&cfg, "byo", &options(GOOD_KEY, true)).await;
    assert!(report.ok, "{}", report.text());
    assert_eq!(step(&report, "prompt").status, StepStatus::Pass, "{}", report.text());
    assert_eq!(report.reply.as_deref(), Some("OK"), "{}", report.text());
    assert!(hits.load(Ordering::SeqCst) >= 1);

    // A wrong key: the fix says so, and the key the harness printed is masked.
    let report = doctor(&cfg, "byo", &options(BAD_KEY, true)).await;
    assert!(!report.ok, "{}", report.text());
    let prompt = step(&report, "prompt");
    assert_eq!(prompt.status, StepStatus::Fail, "{}", report.text());
    assert!(prompt.fix.as_deref().unwrap_or("").contains("check the key"), "{}", report.text());
    let json = serde_json::to_string(&report).unwrap();
    let wire = admin::doctor_value(&report).to_string();
    for text in [&json, &wire, &report.text()] {
        assert!(!text.contains(BAD_KEY), "the key leaked: {text}");
    }
    assert!(json.contains("***"), "the printed key was not masked: {json}");

    // A model the endpoint does not have.
    let cfg = endpoint_config(&root, &url, "missing-model");
    let report = doctor(&cfg, "byo", &options(GOOD_KEY, true)).await;
    let prompt = step(&report, "prompt");
    assert_eq!(prompt.status, StepStatus::Fail, "{}", report.text());
    assert!(prompt.fix.as_deref().unwrap_or("").contains("model not found"), "{}", report.text());

    // Nothing listens at the base URL.
    let dead = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let dead_url = format!("http://127.0.0.1:{}", dead.local_addr().unwrap().port());
    drop(dead);
    let cfg = endpoint_config(&root, &dead_url, "good-model");
    let report = doctor(&cfg, "byo", &options(GOOD_KEY, true)).await;
    let prompt = step(&report, "prompt");
    assert_eq!(prompt.status, StepStatus::Fail, "{}", report.text());
    assert!(
        prompt.fix.as_deref().unwrap_or("").contains("check the base URL"),
        "{}",
        report.text()
    );

    // Without the prompt nothing reaches the endpoint.
    let cfg = endpoint_config(&root, &url, "good-model");
    let before = hits.load(Ordering::SeqCst);
    let report = doctor(&cfg, "byo", &options(GOOD_KEY, false)).await;
    assert!(report.ok, "{}", report.text());
    assert_eq!(step(&report, "prompt").status, StepStatus::Skip, "{}", report.text());
    assert_eq!(hits.load(Ordering::SeqCst), before);
}
