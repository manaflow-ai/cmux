use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Answers each fetch with the next scripted outcome and records the If-None-Match it got.
struct Script {
    answers: Mutex<Vec<Result<FetchOutcome, String>>>,
    seen_etags: Mutex<Vec<Option<String>>>,
    calls: AtomicUsize,
}

impl Script {
    fn new(answers: Vec<Result<FetchOutcome, String>>) -> Arc<Self> {
        Arc::new(Self {
            answers: Mutex::new(answers),
            seen_etags: Mutex::new(Vec::new()),
            calls: AtomicUsize::new(0),
        })
    }
}

impl Fetcher for Script {
    fn fetch<'a>(
        &'a self,
        etag: Option<&'a str>,
    ) -> futures::future::BoxFuture<'a, Result<FetchOutcome, String>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.seen_etags.lock().unwrap().push(etag.map(str::to_owned));
        let mut answers = self.answers.lock().unwrap();
        let next =
            if answers.is_empty() { Err("no more answers".into()) } else { answers.remove(0) };
        Box::pin(async move { next })
    }
}

fn doc(generated_at: &str, model: &str) -> Value {
    json!({
        "schemaVersion": 1,
        "generatedAt": generated_at,
        "source": "live",
        "harnesses": [{
            "id": "codex",
            "name": "Codex",
            "brand": "openai",
            "families": ["codex"],
            "modelSource": "catalog",
            "docsUrl": "https://developers.openai.com/codex/cli",
            "models": [{"id": model, "ref": format!("openai/{model}"), "name": model.to_uppercase(), "shortName": model, "provider": "openai"}],
        }],
        "models": {format!("openai/{model}"): {"name": model.to_uppercase(), "contextWindow": 400000}},
        "providers": {"openai": {"name": "OpenAI"}},
    })
}

fn body(v: &Value) -> FetchOutcome {
    FetchOutcome::Body {
        body: serde_json::to_vec(v).unwrap(),
        etag: Some(format!("\"{}\"", v["generatedAt"].as_str().unwrap_or_default())),
    }
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-catalog-{name}-{}-{}",
        std::process::id(),
        now_ms()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn service(dir: &Path, script: &Arc<Script>) -> CatalogService {
    let bundled = schema::parse(
        &serde_json::to_vec(&doc("2026-01-01T00:00:00.000Z", "bundled-model")).unwrap(),
    )
    .unwrap();
    let service = CatalogService::with_bundled(bundled);
    service.attach(dir.to_owned(), Some(script.clone() as Arc<dyn Fetcher>));
    service
}

fn model_ids(service: &CatalogService) -> Vec<String> {
    service.current().harnesses[0].models.iter().map(|m| m.id.clone()).collect()
}

#[test]
fn the_bundled_copy_reads_and_lists_the_built_in_harnesses() {
    let catalog = schema::parse(BUNDLED.as_bytes()).expect("the bundled catalog is valid");
    let ids: Vec<&str> = catalog.harnesses.iter().map(|h| h.id.as_str()).collect();
    for id in ["claude", "codex", "opencode", "pi"] {
        assert!(ids.contains(&id), "{id} is missing from {ids:?}");
    }
    assert!(BUNDLED.len() < schema::MAX_BODY_BYTES);
    assert_eq!(catalog.source, "snapshot");
}

#[tokio::test]
async fn a_bad_schema_is_refused_and_the_last_good_copy_is_kept() {
    let dir = temp_dir("bad-schema");
    let good = doc("2026-10-01T00:00:00.000Z", "gpt-good");
    let mut wrong_type = good.clone();
    wrong_type["harnesses"][0]["models"][0]["fast"] = json!("yes");
    let mut duplicate = good.clone();
    duplicate["harnesses"][0]["models"] =
        json!([good["harnesses"][0]["models"][0], good["harnesses"][0]["models"][0]]);
    let mut bad_effort = good.clone();
    bad_effort["harnesses"][0]["models"][0]["efforts"] = json!(["warp"]);
    let script = Script::new(vec![
        Ok(body(&good)),
        Ok(body(&wrong_type)),
        Ok(body(&duplicate)),
        Ok(body(&bad_effort)),
        Ok(FetchOutcome::Body { body: b"{not json".to_vec(), etag: None }),
        Ok(body(
            &json!({"schemaVersion": 1, "generatedAt": "2026-10-02T00:00:00.000Z", "source": "live", "harnesses": []}),
        )),
    ]);
    let service = service(&dir, &script);
    assert_eq!(service.refresh(true).await["changed"], true);
    for _ in 0..5 {
        let reply = service.refresh(true).await;
        assert_eq!(reply["changed"], false, "{reply}");
        assert!(reply["error"].as_str().is_some_and(|e| e.contains("not valid")), "{reply}");
        assert_eq!(model_ids(&service), ["gpt-good"]);
    }
    // The stored copy is still the good one: a new daemon starts from it.
    let next = service_without_fetch(&dir);
    assert_eq!(model_ids(&next), ["gpt-good"]);
    assert_eq!(next.summary()["delivery"], "stored");
}

fn service_without_fetch(dir: &Path) -> CatalogService {
    let bundled = schema::parse(
        &serde_json::to_vec(&doc("2026-01-01T00:00:00.000Z", "bundled-model")).unwrap(),
    )
    .unwrap();
    let service = CatalogService::with_bundled(bundled);
    service.attach(dir.to_owned(), None);
    service
}

#[tokio::test]
async fn an_oversize_body_is_refused() {
    let dir = temp_dir("oversize");
    let mut big = doc("2026-10-01T00:00:00.000Z", "gpt-big");
    big["padding"] = json!("x".repeat(schema::MAX_BODY_BYTES));
    let script = Script::new(vec![Ok(body(&big))]);
    let service = service(&dir, &script);
    let reply = service.refresh(true).await;
    assert!(reply["error"].as_str().is_some_and(|e| e.contains("byte limit")), "{reply}");
    assert_eq!(model_ids(&service), ["bundled-model"]);
    assert!(!dir.join(STORE_FILE).exists());
    // The network reader stops at the same limit.
    let mut buf = vec![0; schema::MAX_BODY_BYTES - 1];
    assert!(fetch::push_capped(&mut buf, b"x", schema::MAX_BODY_BYTES).is_ok());
    assert!(fetch::push_capped(&mut buf, b"x", schema::MAX_BODY_BYTES).is_err());
    assert_eq!(buf.len(), schema::MAX_BODY_BYTES);
}

#[tokio::test]
async fn a_304_keeps_the_copy_and_sends_its_etag() {
    let dir = temp_dir("not-modified");
    let good = doc("2026-10-01T00:00:00.000Z", "gpt-good");
    let script = Script::new(vec![Ok(body(&good)), Ok(FetchOutcome::NotModified)]);
    let service = service(&dir, &script);
    service.refresh(true).await;
    let mut events = service.subscribe();
    let reply = service.refresh(true).await;
    assert_eq!(reply["changed"], false, "{reply}");
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(model_ids(&service), ["gpt-good"]);
    assert_eq!(reply["delivery"], "fetched");
    let etags = script.seen_etags.lock().unwrap().clone();
    assert_eq!(etags, [None, Some("\"2026-10-01T00:00:00.000Z\"".to_owned())]);
    assert!(events.try_recv().is_err(), "a 304 announces no change");
}

#[tokio::test]
async fn offline_the_bundled_copy_is_used() {
    let dir = temp_dir("offline");
    let script = Script::new(vec![Err("dns error: no network".into())]);
    let service = service(&dir, &script);
    let reply = service.refresh(true).await;
    assert_eq!(reply["delivery"], "bundled", "{reply}");
    assert!(reply["error"].as_str().is_some_and(|e| e.contains("no network")), "{reply}");
    assert_eq!(model_ids(&service), ["bundled-model"]);
}

#[tokio::test]
async fn a_url_outside_the_allowlist_is_ignored() {
    let dir = temp_dir("url");
    let mut evil = doc("2026-10-01T00:00:00.000Z", "gpt-good");
    evil["harnesses"][0]["docsUrl"] = json!("https://evil.example/install.sh");
    let script = Script::new(vec![Ok(body(&evil))]);
    let service = service(&dir, &script);
    service.refresh(true).await;
    let harness = &service.current().harnesses[0];
    assert_eq!(harness.docs_url, None);
    assert_eq!(model_ids(&service), ["gpt-good"], "the rest of the document is kept");
    for url in [
        "http://docs.claude.com/x",
        "https://user:pw@github.com/x",
        "https://github.com:8443/x",
        "https://github.com.evil.example/x",
        "javascript:alert(1)",
    ] {
        assert!(!schema::allowed_docs_url(url), "{url}");
    }
    assert!(schema::allowed_docs_url("https://github.com/google-gemini/gemini-cli"));
}

#[tokio::test]
async fn a_newer_major_version_keeps_the_current_copy() {
    let dir = temp_dir("version");
    let mut v2 = doc("2027-01-01T00:00:00.000Z", "gpt-future");
    v2["schemaVersion"] = json!(2);
    v2["harnesses"] = json!({"totally": "different"});
    let script = Script::new(vec![Ok(body(&v2))]);
    let service = service(&dir, &script);
    let reply = service.refresh(true).await;
    assert!(reply["error"].as_str().is_some_and(|e| e.contains("version 2")), "{reply}");
    assert_eq!(model_ids(&service), ["bundled-model"]);
}

#[tokio::test]
async fn a_change_is_announced_stored_atomically_and_used_at_the_next_start() {
    let dir = temp_dir("store");
    let script = Script::new(vec![Ok(body(&doc("2026-10-01T00:00:00.000Z", "gpt-new")))]);
    let service = service(&dir, &script);
    let mut events = service.subscribe();
    let reply = service.refresh(true).await;
    assert_eq!(reply["changed"], true, "{reply}");
    let event = events.try_recv().expect("catalog.changed");
    assert_eq!(event["generatedAt"], "2026-10-01T00:00:00.000Z");
    assert_eq!(event["delivery"], "fetched");
    assert_eq!(service.get()["catalog"]["models"]["openai/gpt-new"]["contextWindow"], 400000);
    let names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, [STORE_FILE], "no temporary file is left");
    assert_eq!(model_ids(&service_without_fetch(&dir)), ["gpt-new"]);
}

#[tokio::test]
async fn a_stored_copy_older_than_the_bundled_one_is_not_used() {
    let dir = temp_dir("older");
    let script = Script::new(vec![Ok(body(&doc("2025-06-01T00:00:00.000Z", "gpt-old")))]);
    service(&dir, &script).refresh(true).await;
    let next = service_without_fetch(&dir);
    assert_eq!(model_ids(&next), ["bundled-model"]);
    assert_eq!(next.summary()["delivery"], "bundled");
}

#[tokio::test]
async fn refreshes_close_together_read_the_network_once() {
    let dir = temp_dir("spacing");
    let script = Script::new(vec![Ok(FetchOutcome::NotModified), Ok(FetchOutcome::NotModified)]);
    let service = service(&dir, &script);
    service.refresh(false).await;
    service.refresh(false).await;
    assert_eq!(script.calls.load(Ordering::SeqCst), 1);
    service.refresh(true).await;
    assert_eq!(script.calls.load(Ordering::SeqCst), 2);
}

#[test]
fn only_a_dev_build_takes_the_url_override() {
    assert_eq!(
        fetch::catalog_url(false, Some("https://dev.example/api/models/v1")),
        fetch::CATALOG_URL
    );
    assert_eq!(
        fetch::catalog_url(true, Some("https://dev.example/api/models/v1")),
        "https://dev.example/api/models/v1"
    );
    assert_eq!(
        fetch::catalog_url(true, Some("http://dev.example/api/models/v1")),
        fetch::CATALOG_URL
    );
    assert_eq!(fetch::catalog_url(true, None), fetch::CATALOG_URL);
    assert!(fetch::CATALOG_URL.starts_with("https://"));
}
