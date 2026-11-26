//! The public-feed overlay (`feed.rs`): a model the feed lists reaches the catalog in use
//! the day the feed has it, without a catalog rebuild or a cmux release (user 2026-11-19:
//! "gemini neon didn't automatically appear in model picker for us").

use super::*;
use crate::catalog::feed::{self, FeedSnapshot};
use serde_json::json;
use std::sync::Arc;

/// The catalog as the Oct 29 bundle had it for Gemini CLI: Gemini 3.1 Pro, no Gemini 4.
fn base() -> Catalog {
    schema::parse(
        &serde_json::to_vec(&json!({
            "schemaVersion": 1,
            "generatedAt": "2026-10-29T12:08:55.000Z",
            "source": "snapshot",
            "harnesses": [
                {
                    "id": "gemini", "name": "Gemini CLI", "brand": "gemini", "families": ["gemini"],
                    "modelSource": "catalog", "defaultModel": "gemini-3.1-pro-preview", "runsAnyModel": true,
                    "feed": {
                        "sources": [{"provider": "google", "include": ["gemini-"],
                                     "exclude": ["gemini-embedding", "*-tts", "*-customtools"],
                                     "minReleaseDate": "2025-06-01"}],
                        "shortNamePrefix": "Gemini ",
                        "familyNames": {"gemini": "Gemini", "gemini-pro": "Pro"},
                        "dropEfforts": ["none", "minimal", "low", "medium", "high", "xhigh", "max"],
                        "hidden": ["gemini-4-secret"]
                    },
                    "models": [{"id": "gemini-3.1-pro-preview", "ref": "google/gemini-3.1-pro-preview",
                                "name": "Gemini 3.1 Pro Preview", "shortName": "3.1 Pro Preview",
                                "family": "Pro", "provider": "google"}]
                },
                {"id": "pi", "name": "Pi", "brand": "pi", "families": ["pi"], "modelSource": "probe", "models": []}
            ],
            "models": {"google/gemini-3.1-pro-preview": {"name": "Gemini 3.1 Pro Preview", "releaseDate": "2026-02-19"}},
            "providers": {"google": {"name": "Google"}}
        }))
        .unwrap(),
    )
    .unwrap()
}

/// models.dev's shape (`{provider: {name, models: {id: {...}}}}`), trimmed to what matters.
fn feed_body() -> Vec<u8> {
    serde_json::to_vec(&json!({
        "google": {"id": "google", "name": "Google", "models": {
            "gemini-3.1-pro-preview": {"id": "gemini-3.1-pro-preview", "name": "Gemini 3.1 Pro Preview",
                "family": "gemini-pro", "release_date": "2026-02-19", "tool_call": true},
            "gemini-4-neon": {"id": "gemini-4-neon", "name": "Gemini 4 Neon", "family": "gemini",
                "release_date": "2026-11-18", "tool_call": true, "reasoning": true,
                "reasoning_options": [{"type": "effort", "values": ["low", "medium", "high", "xhigh"]}],
                "limit": {"context": 1048576, "output": 65536},
                "modalities": {"input": ["text", "image", "pdf"]},
                "cost": {"input": 3, "output": 15}},
            "gemini-4-secret": {"id": "gemini-4-secret", "name": "Gemini 4 Secret", "release_date": "2026-11-18", "tool_call": true},
            "gemini-4-tts": {"id": "gemini-4-tts", "name": "Gemini 4 TTS", "release_date": "2026-11-18", "tool_call": true},
            "gemini-4-notools": {"id": "gemini-4-notools", "name": "Gemini 4 No Tools", "release_date": "2026-11-18", "tool_call": false},
            "gemini-1.5-pro": {"id": "gemini-1.5-pro", "name": "Gemini 1.5 Pro", "release_date": "2024-02-15", "tool_call": true},
            "gemini-4-bad": {"id": "gemini-4-bad", "name": 7},
            "gemini-4-flash": {"id": "gemini-4-flash", "name": "Gemini 4 Flash (latest)", "release_date": "2026-11-12",
                "tool_call": "yes", "status": "beta"}
        }},
        "openai": {"id": "openai", "name": "OpenAI", "models": {
            "gpt-9": {"id": "gpt-9", "name": "GPT-9", "release_date": "2026-11-18", "tool_call": true}
        }}
    }))
    .unwrap()
}

fn snapshot() -> FeedSnapshot {
    feed::parse(&feed_body(), &feed::providers_used(&base())).unwrap()
}

fn ids(catalog: &Catalog, harness: &str) -> Vec<String> {
    let entry = catalog.harnesses.iter().find(|h| h.id == harness).unwrap();
    entry.models.iter().map(|m| m.id.clone()).collect()
}

#[test]
fn a_model_the_feed_lists_joins_its_harness_newest_first() {
    let merged = feed::overlay(&base(), &snapshot());
    assert_eq!(
        ids(&merged, "gemini"),
        ["gemini-4-neon", "gemini-4-flash", "gemini-3.1-pro-preview"],
        "new feed models lead; hidden, tts, toolless, old and malformed ones stay out"
    );
    let neon = &merged.harnesses[0].models[0];
    assert_eq!(neon.name, "Gemini 4 Neon");
    assert_eq!(neon.short_name, "4 Neon");
    assert_eq!(neon.family.as_deref(), Some("Gemini"));
    assert_eq!(neon.provider.as_deref(), Some("google"));
    assert_eq!(neon.reference.as_deref(), Some("google/gemini-4-neon"));
    assert_eq!(neon.efforts, None, "Gemini CLI takes no effort: every value is dropped");
    let flash = &merged.harnesses[0].models[1];
    assert_eq!(flash.name, "Gemini 4 Flash", "the feed's (latest) mark is not part of the name");
    assert_eq!(flash.status.as_deref(), Some("preview"));
    let info = &merged.models["google/gemini-4-neon"];
    assert_eq!(info.release_date.as_deref(), Some("2026-11-18"));
    assert_eq!(info.context_window, Some(1_048_576));
    assert_eq!(info.cost.as_ref().and_then(|c| c.output), Some(15.0));
    assert!(ids(&merged, "pi").is_empty(), "a probe harness lists what it reports");
    schema::parse(&serde_json::to_vec(&merged).unwrap()).expect("the merged catalog stays valid");
}

#[test]
fn a_model_the_catalog_already_lists_keeps_the_catalogs_fields() {
    let mut catalog = base();
    catalog.harnesses[0].models[0].short_name = "3.1 Pro".into();
    let merged = feed::overlay(&catalog, &snapshot());
    let row = merged.harnesses[0].models.iter().find(|m| m.id == "gemini-3.1-pro-preview").unwrap();
    assert_eq!(row.short_name, "3.1 Pro");
    assert_eq!(
        merged.models["google/gemini-3.1-pro-preview"].release_date.as_deref(),
        Some("2026-02-19")
    );
}

#[test]
fn a_catalog_without_feed_rules_is_unchanged() {
    let mut catalog = base();
    catalog.harnesses[0].feed = None;
    assert_eq!(feed::overlay(&catalog, &snapshot()), catalog);
}

#[test]
fn only_the_providers_the_rules_name_are_kept_in_memory() {
    let snapshot = snapshot();
    assert!(snapshot.has_models_of("google"));
    assert!(!snapshot.has_models_of("openai"), "no rule names openai: its models are not kept");
}

#[test]
fn a_feed_that_is_not_an_object_is_refused() {
    assert!(feed::parse(b"[1,2]", &feed::providers_used(&base())).is_err());
    assert!(feed::parse(b"not json", &feed::providers_used(&base())).is_err());
}

/// Every provider shape the old `Value`-tree read met, odd ones included: the streamed read
/// keeps exactly what it kept.
fn odd_feed_body() -> Vec<u8> {
    let long = "x".repeat(201);
    format!(
        r#"{{
        "google": {{"name": "Google", "models": {{"m": {{"id": "m", "name": "M"}}}}}},
        "dup": {{"name": "First"}},
        "dup": {{"name": "Second", "models": {{}}}},
        "dup-gone": {{"name": "Kept?"}},
        "dup-gone": 5,
        "twice-named": {{"name": "One", "models": [], "name": "Two"}},
        "text": "a provider that is a string",
        "number": 12.5,
        "negative": -3,
        "flag": true,
        "nothing": null,
        "empty": {{}},
        "array-empty": [],
        "array-name": ["Array Name"],
        "array-pair": ["Pair", {{"m": {{"id": "m", "name": "M"}}}}],
        "array-long": ["Long", {{}}, 3],
        "name-object": {{"name": {{"nested": [1, 2, {{"deep": null}}]}}, "models": 4}},
        "name-blank": {{"name": "   "}},
        "name-long": {{"name": "{long}"}},
        "name-trimmed": {{"name": "  Spaced  ", "extra": {{"a": [true, false, null, "s", 1e300]}}}},
        "openai": {{"name": "OpenAI", "models": {{"gpt": {{"id": "gpt", "name": "GPT", "tool_call": true}}}}}},
        "weird-models": {{"name": "Weird", "models": ["not", "a", "map"]}}
    }}"#
    )
    .into_bytes()
}

#[test]
fn the_streamed_read_keeps_what_the_value_tree_read_kept() {
    let keeps: Vec<std::collections::BTreeSet<String>> = vec![
        feed::providers_used(&base()),
        Default::default(),
        [
            "openai",
            "google",
            "dup",
            "dup-gone",
            "array-pair",
            "array-name",
            "array-long",
            "text",
            "weird-models",
            "name-object",
            "twice-named",
            "absent",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
    ];
    for body in [feed_body(), odd_feed_body()] {
        for keep in &keeps {
            let streamed = feed::parse(&body, keep).expect("the streamed read");
            let tree = feed::parse_tree(&body, keep).expect("the tree read");
            assert_eq!(streamed, tree, "keep {keep:?}");
        }
    }
    for bad in [&b"[1,2]"[..], b"not json", b"{\"a\": {}} trailing", b"{\"a\": ", b"7", b"null"] {
        let keep = feed::providers_used(&base());
        assert!(feed::parse(bad, &keep).is_err());
        assert!(feed::parse_tree(bad, &keep).is_err());
    }
}

#[test]
fn a_gzip_body_is_read_and_a_huge_one_is_refused() {
    use std::io::Write as _;
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    gz.write_all(&feed_body()).unwrap();
    let packed = gz.finish().unwrap();
    assert_eq!(feed::decode(&packed, Some("gzip"), 1 << 20).unwrap(), feed_body());
    assert!(feed::decode(&packed, Some("gzip"), 64).is_err(), "the decoded size is capped");
    assert_eq!(feed::decode(&feed_body(), None, 1 << 20).unwrap(), feed_body());
}

struct FeedOnce(Vec<u8>);

impl Fetcher for FeedOnce {
    fn fetch<'a>(
        &'a self,
        etag: Option<&'a str>,
    ) -> futures::future::BoxFuture<'a, Result<FetchOutcome, String>> {
        let body = self.0.clone();
        let fresh = etag != Some("\"f1\"");
        Box::pin(async move {
            Ok(if fresh {
                FetchOutcome::Body { body, etag: Some("\"f1\"".into()) }
            } else {
                FetchOutcome::NotModified
            })
        })
    }
}

struct Refuses;

impl Fetcher for Refuses {
    fn fetch<'a>(
        &'a self,
        _etag: Option<&'a str>,
    ) -> futures::future::BoxFuture<'a, Result<FetchOutcome, String>> {
        Box::pin(async { Err("the catalog server answered 404".to_owned()) })
    }
}

/// The user's nightly: the catalog server answers 404, so only the bundled copy is there. The
/// feed still brings Gemini 4 Neon into the catalog in use, announces it, and a 304 keeps it.
#[tokio::test]
async fn the_feed_brings_a_new_model_when_the_catalog_server_is_down() {
    let service = Arc::new(CatalogService::with_bundled(base()));
    let dir = tempfile::tempdir().unwrap();
    service.attach(dir.path().to_path_buf(), Some(Arc::new(Refuses)));
    service.attach_feed(Arc::new(FeedOnce(feed_body())));
    let mut changes = service.subscribe();
    assert!(!ids(&service.current(), "gemini").contains(&"gemini-4-neon".to_owned()));
    let reply = service.refresh(true).await;
    assert_eq!(reply["changed"], json!(true), "{reply}");
    assert!(ids(&service.current(), "gemini").contains(&"gemini-4-neon".to_owned()));
    assert!(changes.try_recv().is_ok(), "catalog.changed is announced");
    let again = service.refresh(true).await;
    assert_eq!(again["changed"], json!(false), "a 304 changes nothing: {again}");
    assert!(ids(&service.current(), "gemini").contains(&"gemini-4-neon".to_owned()));
}

/// A stored copy from the catalog server that predates a release never hides it: the feed
/// overlays whatever copy is in use, and a newer copy without the model keeps it too.
#[tokio::test]
async fn a_stale_catalog_copy_never_hides_a_feed_model() {
    let service = Arc::new(CatalogService::with_bundled(base()));
    let dir = tempfile::tempdir().unwrap();
    service.attach(dir.path().to_path_buf(), None);
    service.attach_feed(Arc::new(FeedOnce(feed_body())));
    service.refresh(true).await;
    let mut newer = base();
    newer.generated_at = "2026-11-19T00:00:00.000Z".into();
    service.accept(&serde_json::to_vec(&newer).unwrap(), Some("\"c2\"".into())).unwrap();
    assert!(ids(&service.current(), "gemini").contains(&"gemini-4-neon".to_owned()));
}

/// The live models backend's kill switch: a row marked `disabled` leaves the catalog in use,
/// and the feed, which lists the model, never brings it back.
#[tokio::test]
async fn a_disabled_model_never_shows_even_when_the_feed_lists_it() {
    let service = Arc::new(CatalogService::with_bundled(base()));
    let dir = tempfile::tempdir().unwrap();
    service.attach(dir.path().to_path_buf(), None);
    service.attach_feed(Arc::new(FeedOnce(feed_body())));
    service.refresh(true).await;
    let mut newer = base();
    newer.generated_at = "2026-11-19T00:00:00.000Z".into();
    let mut neon = newer.harnesses[0].models[0].clone();
    neon.id = "gemini-4-neon".into();
    neon.reference = Some("google/gemini-4-neon".into());
    neon.name = "Gemini 4 Neon".into();
    neon.short_name = "4 Neon".into();
    neon.status = Some("disabled".into());
    newer.harnesses[0].models.insert(0, neon);
    newer.harnesses[0].models[1].status = Some("disabled".into());
    service.accept(&serde_json::to_vec(&newer).unwrap(), Some("\"c2\"".into())).unwrap();
    let current = service.current();
    assert_eq!(ids(&current, "gemini"), ["gemini-4-flash"], "both disabled rows are gone");
    assert_eq!(current.harnesses[0].disabled, ["gemini-4-neon", "gemini-3.1-pro-preview"]);
    assert_eq!(current.harnesses[0].default_model, None, "a disabled default is cleared");
    let wire = serde_json::to_value(&*current).unwrap();
    assert!(wire["harnesses"][0].get("disabled").is_none(), "the id list stays off the wire");
    schema::parse(&serde_json::to_vec(&wire).unwrap()).expect("the catalog in use stays valid");
}

#[test]
fn the_catalog_is_read_from_the_live_models_backend_then_cmux_com() {
    use crate::catalog::fetch::{CATALOG_URL, FALLBACK_CATALOG_URL, catalog_urls};
    assert_eq!(CATALOG_URL, "https://cloud-api.cmux.dev/v1/models/catalog");
    assert_eq!(catalog_urls(false, None), [CATALOG_URL, FALLBACK_CATALOG_URL]);
    assert_eq!(
        catalog_urls(false, Some("https://example.test/c")),
        [CATALOG_URL, FALLBACK_CATALOG_URL],
        "a release build ignores the override"
    );
    assert_eq!(catalog_urls(true, Some("https://example.test/c")), ["https://example.test/c"]);
    assert_eq!(
        catalog_urls(true, Some("http://example.test/c")),
        [CATALOG_URL, FALLBACK_CATALOG_URL]
    );
}

#[test]
fn the_daemon_checks_every_hour() {
    assert_eq!(REFRESH_EVERY, std::time::Duration::from_secs(60 * 60));
}
