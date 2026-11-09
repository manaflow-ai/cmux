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
        models: vec![model.into()],
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

    // Without keychainItem or a key: no key reference (nothing that would fail to resolve); the
    // reply names the item `cmux harness secret set ID KEY` writes and points the profile at.
    let added =
        add(&params("anthropic-endpoint", "dflt", "https://llm.example.com", "m1", None), &src)
            .unwrap();
    let (profile, _) = load(&added.path, "dflt");
    assert!(!profile.env.contains_key("ANTHROPIC_AUTH_TOKEN"), "{:?}", profile.env);
    let item = crate::cli::harness_secret::reference("dflt", "ANTHROPIC_AUTH_TOKEN");
    let reply = serde_json::to_value(&added).unwrap();
    assert_eq!(reply["secret"]["keychainItem"], json!(item), "{reply}");
}

#[test]
fn byo_endpoint_openai_profile_configures_opencode_with_a_keychain_key() {
    let root = scratch("openai");
    let src = sources(&root);
    let seen = std::sync::Mutex::new(Vec::<(Vec<String>, String)>::new());
    let store = |c: &StoreCommand| -> anyhow::Result<()> {
        seen.lock().unwrap().push((c.argv.clone(), c.stdin.to_string()));
        Ok(())
    };
    let added = admin::add_endpoint_keyed(
        &params("openai-endpoint", "acme-oai", "https://api.example.com/v1/", "org/model-7b", None),
        &src,
        &admin::EndpointKey { value: Some(GOOD_KEY), store: &store, ..admin::EndpointKey::NONE },
    )
    .unwrap();
    // The key went to the store command's stdin for this profile's own item, never the file.
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert!(seen[0].0.iter().all(|a| !a.contains(GOOD_KEY)), "the value is in argv");
        assert!(seen[0].1.contains(GOOD_KEY));
        assert!(
            seen[0].0.iter().any(|a| a.contains("acme-oai/CMUX_BYO_API_KEY")),
            "{:?}",
            seen[0].0
        );
    }
    assert!(!std::fs::read_to_string(&added.path).unwrap().contains(GOOD_KEY));
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
    p.models.clear();
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

    // A harness not added yet (the app stores an endpoint's key, then adds the profile that
    // names it): the item is stored and nothing is pointed at it yet.
    let done = admin::secret_set("new-one", "API_KEY", GOOD_KEY, &cfg, &store).unwrap();
    let reply = serde_json::to_value(&done).unwrap();
    assert_eq!(reply["profile"], "pending", "{reply}");
    assert_eq!(
        reply["keychainItem"],
        json!(crate::cli::harness_secret::reference("new-one", "API_KEY")),
        "{reply}"
    );
    assert!(!reply.to_string().contains(GOOD_KEY), "{reply}");
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert!(seen[1].0.iter().all(|a| !a.contains(GOOD_KEY)), "the value is in argv");
    }
    // Not an id: nothing is stored.
    let e = admin::secret_set("Not An Id", "API_KEY", GOOD_KEY, &cfg, &store).unwrap_err();
    assert!(matches!(e, AdminError::Invalid(_)), "{e}");
    assert_eq!(seen.lock().unwrap().len(), 2);
    // A failing store names no value.
    let failing = |_: &StoreCommand| -> anyhow::Result<()> { anyhow::bail!("security failed") };
    let e = admin::secret_set("sec", "ANTHROPIC_AUTH_TOKEN", GOOD_KEY, &cfg, &failing).unwrap_err();
    assert!(!e.message().contains(GOOD_KEY), "{e}");
}

#[test]
fn byo_endpoint_several_models_fill_the_picker_and_claude_codes_slots() {
    let root = scratch("models");
    let src = sources(&root);
    // One string with commas (what the app's add sends) and a repeated entry.
    let mut p = params("anthropic-endpoint", "gw", "https://gw.example.com", "big, mid", None);
    p.models.push("small".into());
    p.models.push("mid".into());
    let added = add(&p, &src).unwrap();
    assert!(added.diagnostics.is_empty(), "{:?}", added.diagnostics);
    let (profile, _) = load(&added.path, "gw");
    let ids: Vec<&str> = profile.models.iter().map(|m| m.id()).collect();
    assert_eq!(ids, ["big", "mid", "small"]);
    assert_eq!(profile.model.as_deref(), Some("big"));
    let env = &profile.env;
    assert_eq!(env["ANTHROPIC_MODEL"], "big");
    assert_eq!(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "big");
    assert_eq!(env["ANTHROPIC_DEFAULT_SONNET_MODEL"], "mid");
    assert_eq!(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "small");
    assert_eq!(env["ANTHROPIC_SMALL_FAST_MODEL"], "small");

    // Two models: Haiku takes Sonnet's; one model fills every slot.
    let two = ["a".to_owned(), "b".to_owned()];
    let slots = claude_slots(&two);
    assert_eq!(slots.map(|(_, m)| m), ["a", "b", "b", "b"]);
    let one = ["only".to_owned()];
    let slots = claude_slots(&one);
    assert_eq!(slots.map(|(_, m)| m), ["only"; 4]);

    // OpenCode: every model in provider.byo.models and the picker, the first the default.
    let p =
        params("openai-endpoint", "oc", "http://127.0.0.1:11434/v1", "qwen3,org/coder-7b", None);
    let added = add(&p, &src).unwrap();
    let (profile, _) = load(&added.path, "oc");
    let ids: Vec<&str> = profile.models.iter().map(|m| m.id()).collect();
    assert_eq!(ids, ["byo/qwen3", "byo/org/coder-7b"]);
    assert_eq!(profile.model.as_deref(), Some("byo/qwen3"));
    let config: Value = serde_json::from_str(&profile.env["OPENCODE_CONFIG_CONTENT"]).unwrap();
    let listed = config["provider"]["byo"]["models"].as_object().unwrap();
    let mut keys: Vec<&String> = listed.keys().collect();
    keys.sort();
    assert_eq!(keys, ["org/coder-7b", "qwen3"], "{config}");
    assert_eq!(config["model"], "byo/qwen3", "{config}");

    // A bad id anywhere in the list refuses the add; `*` is filled in before add, never written.
    for list in ["good,two words", "a,{env:HOME}"] {
        let p = params("openai-endpoint", "bad", "https://x.example.com", list, None);
        assert!(matches!(add(&p, &src), Err(AdminError::Invalid(_))), "{list}");
    }
    let p = params("openai-endpoint", "bad", "https://x.example.com", "*", None);
    assert!(matches!(add(&p, &src), Err(AdminError::Invalid(_))));
    assert!(!root.join("harnesses").join("bad.toml").exists());
    let many: Vec<String> = (0..=MAX_MODELS).map(|i| format!("m{i}")).collect();
    assert!(check_models(&many).is_err());
    assert_eq!(check_models(&[" a , *,a ".to_owned()]).unwrap(), ["a", "*"]);
}

#[test]
fn byo_endpoint_add_never_writes_over_a_profile_without_replace() {
    let root = scratch("again");
    let src = sources(&root);
    let mut p = params("openai-endpoint", "again", "https://x.example.com/v1", "m1", None);
    add(&p, &src).unwrap();
    // Another add of the same id (another preset whose name made the same id) is refused and
    // the first profile stays; only an add that asks to replace it writes it again.
    let other = params("openai-endpoint", "again", "https://other.example.com/v1", "m9", None);
    match add(&other, &src) {
        Err(e @ AdminError::Exists(_)) => assert_eq!(e.reason(), Some("harness.exists")),
        r => panic!("{r:?}"),
    }
    let path = root.join("harnesses").join("again.toml");
    assert!(std::fs::read_to_string(&path).unwrap().contains("https://x.example.com/v1"));
    p.replace = true;
    p.models = vec!["m2".into()];
    let added = add(&p, &src).unwrap();
    let (profile, _) = load(&added.path, "again");
    assert_eq!(profile.model.as_deref(), Some("byo/m2"));
}

#[test]
fn byo_endpoint_model_lists_parse_from_every_shape() {
    // OpenAI's and Anthropic's shape.
    let openai =
        r#"{"object":"list","data":[{"id":"qwen3","object":"model"},{"id":"org/coder-7b"}]}"#;
    assert_eq!(parse_models(openai).unwrap(), ["qwen3", "org/coder-7b"]);
    let anthropic =
        r#"{"data":[{"type":"model","id":"big","display_name":"Big"}],"has_more":false}"#;
    assert_eq!(parse_models(anthropic).unwrap(), ["big"]);
    // A local server's own shape: `name` or `model`.
    let local = r#"{"models":[{"name":"llama3:8b","model":"llama3:8b"},{"model":"phi4"}]}"#;
    assert_eq!(parse_models(local).unwrap(), ["llama3:8b", "phi4"]);
    // Repeats, ids the profile may not hold, and non-strings are left out.
    let messy =
        r#"{"data":[{"id":"a"},{"id":"a"},{"id":"two words"},{"id":"${HOME}"},{"id":7},"b"]}"#;
    assert_eq!(parse_models(messy).unwrap(), ["a", "b"]);
    assert!(parse_models("<html>").is_err());
    assert!(parse_models(r#"{"error":"nope"}"#).is_err());
    let many =
        json!({"data": (0..500).map(|i| json!({"id": format!("m{i}")})).collect::<Vec<_>>()});
    assert_eq!(parse_models(&many.to_string()).unwrap().len(), MAX_MODELS);
    // Where each API lists its models.
    assert_eq!(
        models_url(Kind::OpenAi, "http://127.0.0.1:1234/v1/"),
        "http://127.0.0.1:1234/v1/models"
    );
    assert_eq!(
        models_url(Kind::Anthropic, "https://gw.example.com"),
        "https://gw.example.com/v1/models"
    );
    assert_eq!(
        models_url(Kind::Anthropic, "https://gw.example.com/v1"),
        "https://gw.example.com/v1/models"
    );
}

/// A one-thread fake `/v1/models` on 127.0.0.1: the list for `Bearer
/// GOOD_KEY` (or any request when `open`), else 401; the auth headers seen.
fn fake_models(open: bool, seen: Arc<std::sync::Mutex<Vec<String>>>) -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            let _ = reader.read_line(&mut line);
            let path = line.split_whitespace().nth(1).unwrap_or("").to_owned();
            let mut auth = String::new();
            loop {
                let mut header = String::new();
                if reader.read_line(&mut header).is_err() || header.trim_end().is_empty() {
                    break;
                }
                if let Some((name, value)) = header.trim_end().split_once(':') {
                    let name = name.trim().to_ascii_lowercase();
                    if name == "authorization" || name == "x-api-key" {
                        auth = value.trim().to_owned();
                        seen.lock().unwrap().push(format!("{name}: {auth}"));
                    }
                }
            }
            let (status, body) = if path != "/v1/models" {
                ("404 Not Found", "Not Found".to_owned())
            } else if !open && auth != format!("Bearer {GOOD_KEY}") && auth != GOOD_KEY {
                ("401 Unauthorized", r#"{"error":"bad key"}"#.to_owned())
            } else {
                ("200 OK", r#"{"data":[{"id":"served-a"},{"id":"served-b"}]}"#.to_owned())
            };
            let mut stream = stream;
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
        }
    });
    port
}

#[tokio::test(flavor = "multi_thread")]
async fn byo_endpoint_fetches_the_model_list_and_fills_in_star() {
    let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let port = fake_models(false, seen.clone());
    let base = format!("http://127.0.0.1:{port}/v1");
    let t = Duration::from_secs(5);
    assert_eq!(
        fetch_models(Kind::OpenAi, &base, Some(GOOD_KEY), t).await.unwrap(),
        ["served-a", "served-b"]
    );
    // Anthropic: `<base>/v1/models`, the key as a bearer token and x-api-key.
    let root_base = format!("http://127.0.0.1:{port}");
    assert_eq!(
        fetch_models(Kind::Anthropic, &root_base, Some(GOOD_KEY), t).await.unwrap().len(),
        2
    );
    assert!(seen.lock().unwrap().iter().any(|h| h.starts_with("x-api-key")));
    // A refused key, a wrong path and a closed port each say so, never with the key.
    let e = fetch_models(Kind::OpenAi, &base, Some(BAD_KEY), t).await.unwrap_err();
    assert!(e.contains("refused the key") && !e.contains(BAD_KEY), "{e}");
    let e = fetch_models(Kind::OpenAi, &format!("http://127.0.0.1:{port}/api"), None, t)
        .await
        .unwrap_err();
    assert!(e.contains("no model list"), "{e}");
    let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let e = fetch_models(Kind::OpenAi, &format!("http://127.0.0.1:{closed}/v1"), None, t)
        .await
        .unwrap_err();
    assert!(e.contains("not reached"), "{e}");
    // Plain http only to this machine.
    let e = fetch_models(Kind::OpenAi, "http://llm.example.com/v1", None, t).await.unwrap_err();
    assert!(e.contains("https"), "{e}");

    // The add's `*`: typed models first, then the endpoint's, the key read from the item.
    let mut p = params("openai-endpoint", "fetch", &base, "mine,*", Some("byo-test/key"));
    let looked = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let log = looked.clone();
    let fetch_root = scratch("fetch-src");
    let fsrc = sources(&fetch_root);
    admin::fetch_endpoint_models(&mut p, None, &fsrc, move |service, account| {
        log.lock().unwrap().push(format!("{service}/{}", account.unwrap_or("")));
        Ok(GOOD_KEY.to_owned())
    })
    .await
    .unwrap();
    assert_eq!(p.models, ["mine", "served-a", "served-b"]);
    assert_eq!(*looked.lock().unwrap(), ["byo-test/key"]);
    let root = scratch("fetch");
    let added = add(&p, &sources(&root)).unwrap();
    let (profile, _) = load(&added.path, "fetch");
    assert_eq!(profile.models.len(), 3);
    // No key in the Keychain: asked without one; the endpoint's refusal is the error.
    let mut p = params("openai-endpoint", "fetch", &base, "*", None);
    let e = admin::fetch_endpoint_models(&mut p, None, &fsrc, |_, _| Err("not found".into()))
        .await
        .unwrap_err();
    assert!(e.message().contains("refused the key"), "{e}");
    // A keyless local server answers without one.
    let open = fake_models(true, Arc::new(std::sync::Mutex::new(Vec::new())));
    let mut p =
        params("openai-endpoint", "local", &format!("http://127.0.0.1:{open}/v1"), "*", None);
    admin::fetch_endpoint_models(&mut p, None, &fsrc, |_, _| Err("not found".into()))
        .await
        .unwrap();
    assert_eq!(p.models, ["served-a", "served-b"]);
    // Without `*` nothing is asked.
    let mut p = params("openai-endpoint", "x", "http://127.0.0.1:9/v1", "m", None);
    admin::fetch_endpoint_models(&mut p, None, &fsrc, |_, _| panic!("no lookup")).await.unwrap();
    assert_eq!(p.models, ["m"]);
    // The key the add brings is used as is: no Keychain lookup.
    let mut p = params("openai-endpoint", "fetch", &base, "*", None);
    admin::fetch_endpoint_models(&mut p, Some(GOOD_KEY), &fsrc, |_, _| panic!("no lookup"))
        .await
        .unwrap();
    assert_eq!(p.models, ["served-a", "served-b"]);
}

/// Added to `written` once the fake is done writing (far past any byte count).
const DONE: usize = 1 << 40;

/// A fake `/v1/models` that answers 200 with a body past the cap: chunked (no
/// length), or with a declared length past it and nothing after; the bytes it
/// managed to write, for the reader's stop.
fn fake_huge_models(declared: bool) -> (u16, Arc<AtomicUsize>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let written = Arc::new(AtomicUsize::new(0));
    let count = written.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() || line.trim_end().is_empty() {
                    break;
                }
            }
            let mut stream = stream;
            if declared {
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n",
                    MAX_LIST_BYTES * 4
                );
                continue;
            }
            let _ = write!(
                stream,
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n"
            );
            let chunk = vec![b' '; 64 * 1024];
            // Up to sixteen times the cap (more than the cap and every socket buffer between); a
            // reader that stops at the cap closes the socket, and a write fails first.
            for _ in 0..(MAX_LIST_BYTES * 16 / chunk.len()) {
                if write!(stream, "{:x}\r\n", chunk.len()).is_err()
                    || stream.write_all(&chunk).is_err()
                    || stream.write_all(b"\r\n").is_err()
                {
                    break;
                }
                count.fetch_add(chunk.len(), Ordering::SeqCst);
            }
            let _ = stream.write_all(b"0\r\n\r\n");
            // Done writing: `written` holds what went out before the reader closed.
            count.fetch_add(DONE, Ordering::SeqCst);
        }
    });
    (port, written)
}

#[tokio::test(flavor = "multi_thread")]
async fn byo_endpoint_a_model_list_past_the_cap_is_refused_while_it_streams() {
    let t = Duration::from_secs(10);
    let (port, written) = fake_huge_models(false);
    let e = fetch_models(Kind::OpenAi, &format!("http://127.0.0.1:{port}/v1"), None, t)
        .await
        .unwrap_err();
    assert!(e.contains("too large"), "{e}");
    // The reader stopped near the cap, not after the whole body: the writer's next writes failed.
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while written.load(Ordering::SeqCst) < DONE && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    let sent = written.load(Ordering::SeqCst);
    assert!(sent >= DONE, "the writer never finished");
    assert!(sent - DONE < MAX_LIST_BYTES * 16, "the whole body was read");
    // A declared length past the cap is refused before any of the body is read.
    let (port, _) = fake_huge_models(true);
    let e = fetch_models(Kind::OpenAi, &format!("http://127.0.0.1:{port}/v1"), None, t)
        .await
        .unwrap_err();
    assert!(e.contains("too large"), "{e}");
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

/// A store that records each (account argv, stdin) and may fail.
fn recording(
    fail: bool,
) -> (Arc<std::sync::Mutex<Vec<String>>>, impl Fn(&StoreCommand) -> anyhow::Result<()> + Sync) {
    let log = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let seen = log.clone();
    (log, move |c: &StoreCommand| {
        if fail {
            anyhow::bail!("the store is locked");
        }
        seen.lock().unwrap().push(format!("{} | {}", c.argv.join(" "), &*c.stdin));
        Ok(())
    })
}

#[test]
fn byo_endpoint_concurrent_adds_of_one_id_store_one_key_under_its_own_profile() {
    let root = scratch("race");
    let src = sources(&root);
    let (log, store) = recording(false);
    let keys = ["sk-race-first-1a2b3c", "sk-race-second-4d5e6f"];
    let barrier = std::sync::Barrier::new(keys.len());
    let results: Vec<_> = std::thread::scope(|s| {
        let handles: Vec<_> = keys
            .iter()
            .map(|key| {
                let (src, store, barrier) = (&src, &store, &barrier);
                s.spawn(move || {
                    let p =
                        params("openai-endpoint", "race", "https://api.example.com/v1", "m", None);
                    barrier.wait();
                    admin::add_endpoint_keyed(
                        &p,
                        src,
                        &admin::EndpointKey { value: Some(key), store, ..admin::EndpointKey::NONE },
                    )
                    .map(|_| *key)
                })
            })
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });
    // Exactly one wins; the other is refused before its key is stored.
    let won: Vec<&str> = results.iter().filter_map(|r| r.as_ref().ok().copied()).collect();
    assert_eq!(won.len(), 1, "{results:?}");
    assert!(
        results.iter().any(
            |r| matches!(r, Err(e @ AdminError::Exists(_)) if e.reason() == Some("harness.exists"))
        ),
        "{results:?}"
    );
    let log = log.lock().unwrap();
    assert_eq!(log.len(), 1, "{log:?}");
    assert!(log[0].contains(won[0]) && log[0].contains("race/CMUX_BYO_API_KEY"), "{log:?}");
    // The surviving profile names that one item: its own, by id.
    let (profile, _) = load(&root.join("harnesses").join("race.toml"), "race");
    let item = crate::cli::harness_secret::reference("race", OPENAI_KEY_ENV);
    assert_eq!(profile.env[OPENAI_KEY_ENV], format!("${{keychain:{item}}}"));

    // An id another source has (a built-in) is refused too, before any key is stored.
    let (log, store) = recording(false);
    let p = params("openai-endpoint", "claude", "https://api.example.com/v1", "m", None);
    let taken = |id: &str| id == "claude";
    let e = admin::add_endpoint_keyed(
        &p,
        &src,
        &admin::EndpointKey { value: Some(keys[0]), store: &store, taken: &taken },
    )
    .unwrap_err();
    assert_eq!(e.reason(), Some("harness.exists"), "{e}");
    assert!(log.lock().unwrap().is_empty());
    assert!(!root.join("harnesses").join("claude.toml").exists());
}

#[test]
fn byo_endpoint_a_keyed_add_keeps_or_rolls_back_its_profile() {
    let root = scratch("keyed");
    let src = sources(&root);
    let path = root.join("harnesses").join("team.toml");
    // A key and a keychainItem together are refused (the key goes in the profile's own item).
    let (_, store) = recording(false);
    let mut p = params("openai-endpoint", "team", "https://api.example.com/v1", "m", Some("x/y"));
    let e = admin::add_endpoint_keyed(
        &p,
        &src,
        &admin::EndpointKey { value: Some(GOOD_KEY), store: &store, ..admin::EndpointKey::NONE },
    )
    .unwrap_err();
    assert!(matches!(e, AdminError::Invalid(_)), "{e}");
    // A store that fails: no profile is left that names a key that is not there.
    p.keychain_item = None;
    let (_, failing) = recording(true);
    let e = admin::add_endpoint_keyed(
        &p,
        &src,
        &admin::EndpointKey { value: Some(GOOD_KEY), store: &failing, ..admin::EndpointKey::NONE },
    )
    .unwrap_err();
    assert!(e.message().contains("not stored") && !e.message().contains(GOOD_KEY), "{e}");
    assert!(!path.exists());
    // A profile an older app wrote names `.../API_KEY`: a replace without a key keeps that item.
    let old = params(
        "openai-endpoint",
        "team",
        "https://api.example.com/v1",
        "m",
        Some("cmux-harness/team/API_KEY"),
    );
    add(&old, &src).unwrap();
    p.replace = true;
    p.models = vec!["m2".into()];
    add(&p, &src).unwrap();
    let (profile, _) = load(&path, "team");
    assert_eq!(profile.env[OPENAI_KEY_ENV], "${keychain:cmux-harness/team/API_KEY}");
    assert_eq!(profile.model.as_deref(), Some("byo/m2"));
    // A replace whose store fails puts the profile back as it was.
    let before = std::fs::read_to_string(&path).unwrap();
    p.models = vec!["m3".into()];
    admin::add_endpoint_keyed(
        &p,
        &src,
        &admin::EndpointKey { value: Some(GOOD_KEY), store: &failing, ..admin::EndpointKey::NONE },
    )
    .unwrap_err();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), before);
}

#[tokio::test(flavor = "multi_thread")]
async fn byo_endpoint_a_keyless_endpoint_names_no_key_and_its_env_resolves() {
    let root = scratch("keyless");
    let src = sources(&root);
    let p = params("openai-endpoint", "local", "http://127.0.0.1:11434/v1", "qwen3", None);
    let added = add(&p, &src).unwrap();
    let text = std::fs::read_to_string(&added.path).unwrap();
    assert!(!text.contains("keychain ="), "{text}");
    let (mut profile, meta) = load(&added.path, "local");
    assert!(!profile.env.contains_key(OPENAI_KEY_ENV), "{:?}", profile.env);
    // Any program that is there: the env step comes after the command step.
    profile.argv[0] = fake_claude(&root).to_string_lossy().into_owned();
    let inline: Value = serde_json::from_str(&profile.env["OPENCODE_CONFIG_CONTENT"]).unwrap();
    assert!(inline["provider"]["byo"]["options"].get("apiKey").is_none(), "{inline}");
    // The doctor's env step (what startup resolves) passes with no Keychain at all.
    let cfg = config("local", profile, meta);
    let mut opts = options(GOOD_KEY, false);
    opts.lookup_keychain = Box::new(|_, _| Err("no Keychain".into()));
    let report = doctor(&cfg, "local", &opts).await;
    assert_eq!(step(&report, "env").status, StepStatus::Pass, "{}", report.text());
}

#[tokio::test(flavor = "multi_thread")]
async fn byo_endpoint_a_removed_endpoints_key_is_deleted_and_never_reused_by_a_fresh_add() {
    let root = scratch("stale");
    let src = sources(&root);
    let home = root.join("home");
    let (log, store) = recording(false);
    let p = params("openai-endpoint", "team", "https://one.example.com/v1", "m", None);
    let added = admin::add_endpoint_keyed(
        &p,
        &src,
        &admin::EndpointKey { value: Some(GOOD_KEY), store: &store, ..admin::EndpointKey::NONE },
    )
    .unwrap();
    let (profile, meta) = load(&added.path, "team");
    let cfg = config("team", profile, meta);
    // Remove (Settings' Remove, or a form's cleanup): the key in this id's own item goes too.
    let forgot = std::sync::Mutex::new(Vec::<Vec<String>>::new());
    let forget = |c: &StoreCommand| -> anyhow::Result<()> {
        assert!(c.stdin.is_empty());
        forgot.lock().unwrap().push(c.argv.clone());
        Ok(())
    };
    admin::remove("team", &cfg, &src, &home, &forget).unwrap();
    let forgot = forgot.into_inner().unwrap();
    assert_eq!(forgot.len(), 1, "{forgot:?}");
    assert!(forgot[0].iter().any(|a| a == "team/CMUX_BYO_API_KEY"), "{forgot:?}");
    assert!(forgot[0].iter().all(|a| !a.contains(GOOD_KEY)));
    // A fresh add of the same id without a key (another URL) names no item, even if one were left,
    // and its `*` is asked for without any key: no lookup at all.
    let mut fresh = params("openai-endpoint", "team", "http://127.0.0.1:9/v1", "m2", None);
    let added = admin::add_endpoint_keyed(&fresh, &src, &admin::EndpointKey::NONE).unwrap();
    let (profile, _) = load(&added.path, "team");
    assert!(!profile.env.contains_key(OPENAI_KEY_ENV), "{:?}", profile.env);
    let open = fake_models(true, Arc::new(std::sync::Mutex::new(Vec::new())));
    fresh.base_url = Some(format!("http://127.0.0.1:{open}/v1"));
    fresh.models = vec!["*".into()];
    admin::fetch_endpoint_models(&mut fresh, None, &src, |_, _| panic!("a fresh add read a key"))
        .await
        .unwrap();
    assert_eq!(fresh.models, ["served-a", "served-b"]);
    assert_eq!(log.lock().unwrap().len(), 1);
    // A profile that is not an endpoint, or an item outside this id's space: nothing deleted.
    let other =
        "schema = 1\nid = \"x\"\ncommand = \"x\"\n[env]\nK = { keychain = \"cmux-harness/x/K\" }\n";
    std::fs::write(root.join("harnesses").join("x.toml"), other).unwrap();
    let none = |_: &StoreCommand| -> anyhow::Result<()> { panic!("deleted a key it does not own") };
    admin::remove("x", &Config::default(), &src, &home, &none).unwrap();
}

#[test]
fn byo_endpoint_adds_wait_on_an_os_lock_other_processes_share() {
    let root = scratch("flock");
    let src = sources(&root);
    let dir = root.join("harnesses");
    std::fs::create_dir_all(&dir).unwrap();
    // Another process (here: another open file) holds the add lock.
    let held = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(".endpoint-add.lock"))
        .unwrap();
    held.lock().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let src2 = src.clone();
    let worker = std::thread::spawn(move || {
        let p = params("openai-endpoint", "locked", "https://api.example.com/v1", "m", None);
        let r = admin::add_endpoint_keyed(&p, &src2, &admin::EndpointKey::NONE).map(|a| a.id);
        tx.send(r).unwrap();
    });
    assert!(
        rx.recv_timeout(Duration::from_millis(300)).is_err(),
        "the add did not wait for the lock"
    );
    assert!(!dir.join("locked.toml").exists());
    held.unlock().unwrap();
    assert_eq!(rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(), "locked");
    worker.join().unwrap();
}

#[test]
fn byo_endpoint_a_remove_and_an_add_of_one_id_never_leave_a_profile_without_its_key() {
    // A form's cleanup removes `team` while another add of `team` (with a new key) runs: the remove
    // and the add take the same OS lock, so the remove never deletes the key of an add that came
    // between its move and its deletion.
    for round in 0..20 {
        let root = scratch(&format!("rmrace{round}"));
        let src = sources(&root);
        let home = root.join("home");
        let events = std::sync::Mutex::new(Vec::<&'static str>::new());
        let store = |_: &StoreCommand| -> anyhow::Result<()> {
            events.lock().unwrap().push("store");
            Ok(())
        };
        let p = params("openai-endpoint", "team", "https://one.example.com/v1", "m", None);
        let first = admin::add_endpoint_keyed(
            &p,
            &src,
            &admin::EndpointKey {
                value: Some(GOOD_KEY),
                store: &store,
                ..admin::EndpointKey::NONE
            },
        )
        .unwrap();
        let (profile, meta) = load(&first.path, "team");
        let cfg = config("team", profile, meta);
        let forget = |_: &StoreCommand| -> anyhow::Result<()> {
            events.lock().unwrap().push("delete");
            Ok(())
        };
        let barrier = std::sync::Barrier::new(2);
        let path = first.path.clone();
        std::thread::scope(|s| {
            s.spawn(|| {
                barrier.wait();
                let _ = admin::remove("team", &cfg, &src, &home, &forget);
            });
            s.spawn(|| {
                barrier.wait();
                let p = params("openai-endpoint", "team", "https://two.example.com/v1", "m", None);
                let _ = admin::add_endpoint_keyed(
                    &p,
                    &src,
                    &admin::EndpointKey {
                        value: Some(BAD_KEY),
                        store: &store,
                        ..admin::EndpointKey::NONE
                    },
                );
            });
        });
        let events = events.into_inner().unwrap();
        // Either the add came first (refused: the profile was there) and the remove then took it
        // and its key, or the remove came first and the add's profile and key both stand.
        if path.exists() {
            assert_eq!(
                events.last(),
                Some(&"store"),
                "round {round}: a profile whose key was deleted: {events:?}"
            );
            assert!(std::fs::read_to_string(&path).unwrap().contains("two.example.com"));
        } else {
            assert_eq!(events.last(), Some(&"delete"), "round {round}: {events:?}");
        }
    }
}

#[test]
fn byo_endpoint_an_add_never_writes_over_another_sources_id_even_with_replace() {
    let root = scratch("othersrc");
    let src = sources(&root);
    let (log, store) = recording(false);
    let taken = |id: &str| id == "corp";
    let mut p = params("openai-endpoint", "corp", "https://api.example.com/v1", "m", None);
    p.replace = true;
    let e = admin::add_endpoint_keyed(
        &p,
        &src,
        &admin::EndpointKey { value: Some(GOOD_KEY), store: &store, taken: &taken },
    )
    .unwrap_err();
    assert_eq!(e.reason(), Some("harness.exists"), "{e}");
    assert!(e.message().contains("another source"), "{e}");
    assert!(log.lock().unwrap().is_empty());
    assert!(!root.join("harnesses").join("corp.toml").exists());
}
