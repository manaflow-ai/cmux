//! The curated model and harness catalog (MODEL-CATALOG-CURATED-PROXY):
//! which harnesses the pickers list and which models each offers, so a new
//! model reaches users without an app or acpmux update.
//!
//! Sources, the first that holds a valid copy wins:
//! 1. the last good copy fetched from [`fetch::CATALOG_URL`], kept in
//!    `$ACPMUX_HOME/catalog/models-v1.json` (written atomically);
//! 2. the copy bundled in this binary (`catalog/models-v1.json`, generated
//!    from `web/data/model-catalog` by `web/tools/refresh-model-catalog-snapshot.ts`).
//!
//! A stored copy older than the bundled one (an app update shipped newer
//! data) loses to it. Over whichever copy is in use, the public model feed
//! ([`feed`], read directly) adds the models the copy's harness rules select
//! and it lacks, so a stale or unreachable catalog never hides a new model.
//! The daemon fetches both at start and every hour with If-None-Match;
//! `catalog.refresh` fetches now. A body that is too big, not valid, or of a
//! newer major schema version never replaces the current copy. Every change
//! is announced to every connection as `catalog.changed`.

use cmux_json::JsonSet as _;

pub mod feed;
pub mod fetch;
pub mod schema;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::broadcast;

pub use fetch::{FetchOutcome, Fetcher, HttpsFetcher};
pub use schema::{Catalog, CatalogError, CatalogHarness, HarnessModel, ModelInfo};

/// `catalog.get {}`: the catalog in use, `{catalog, ...summary}`.
pub const RPC_GET: &str = "catalog.get";
/// `catalog.refresh {}`: fetch now. Reply: [`CatalogService::summary`] plus `changed` and, when the fetch failed, `error`.
pub const RPC_REFRESH: &str = "catalog.refresh";
/// `catalog.changed {schemaVersion, generatedAt, source, delivery}`: sent to every connection when the catalog in use changes.
pub const EVENT_CHANGED: &str = "catalog.changed";
/// How often the daemon checks for a new catalog and feed: each check is a conditional GET that
/// costs no body when nothing changed, so a model released today shows within the hour.
pub const REFRESH_EVERY: Duration = Duration::from_secs(60 * 60);
/// A refresh request within this long of the last network read answers from the current copy.
pub const MIN_FETCH_SPACING: Duration = Duration::from_secs(10);
const STORE_FILE: &str = "models-v1.json";

/// The copy bundled at build time.
pub static BUNDLED: cmux_embed::PackedStr =
    cmux_embed::packed_str!(include_str!("../../catalog/models-v1.json"));

/// Where the catalog in use came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Bundled,
    Stored,
    Fetched,
}

/// The stored file: the catalog body as the server sent it, with its ETag.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredCopy {
    etag: Option<String>,
    fetched_at_ms: u64,
    catalog: Value,
}

struct State {
    /// The catalog in use: `base` with the feed's additions.
    catalog: Arc<Catalog>,
    /// The fetched, stored or bundled copy.
    base: Arc<Catalog>,
    feed: Option<Arc<feed::FeedSnapshot>>,
    feed_etag: Option<String>,
    feed_at_ms: Option<u64>,
    feed_error: Option<String>,
    source: Source,
    etag: Option<String>,
    fetched_at_ms: Option<u64>,
    last_error: Option<String>,
    last_fetch: Option<std::time::Instant>,
}

pub struct CatalogService {
    state: Mutex<State>,
    dir: Mutex<Option<PathBuf>>,
    fetcher: Mutex<Option<Arc<dyn Fetcher>>>,
    feed_fetcher: Mutex<Option<Arc<dyn Fetcher>>>,
    /// One network read at a time.
    refreshing: tokio::sync::Mutex<()>,
    changed: broadcast::Sender<Value>,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// The bundled copy. It is checked by a test, so a bad one never ships; if it
/// still fails to read, the catalog is empty and harnesses keep their own lists.
fn bundled() -> Catalog {
    schema::parse(BUNDLED.inflate().as_bytes()).unwrap_or_else(|e| {
        tracing::error!("the bundled model catalog does not read: {e}");
        Catalog {
            schema_version: schema::SCHEMA_VERSION,
            generated_at: "1970-01-01T00:00:00.000Z".into(),
            source: "snapshot".into(),
            harnesses: Vec::new(),
            models: Default::default(),
            providers: Default::default(),
        }
    })
}

/// Writes `bytes` to `path` through a temporary file in the same folder, so a reader sees the old
/// or the new file ([`crate::config::write_atomic`], which also removes the copies of a writer
/// stopped before its rename).
fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().ok_or_else(|| std::io::Error::other("no parent folder"))?;
    // A refresh that ends after the home was lost never makes it again (`config::mark_home_lost`).
    crate::config::refuse_lost_home(path).map_err(std::io::Error::other)?;
    // Through the folder this daemon holds (`home_fs`): a home replaced after the check never
    // gets the file. Owner-only whatever the umask, like the rest of the acpmux home.
    crate::home_fs::create_dir_all(dir, 0o700)?;
    crate::config::write_atomic_checked(path, bytes).map_err(std::io::Error::other)
}

impl State {
    /// Takes `base` as the copy in use, with the last feed read's additions over it and its
    /// disabled models dropped.
    fn set_base(&mut self, base: Catalog) {
        let mut catalog = match &self.feed {
            Some(snapshot) => feed::overlay(&base, snapshot),
            None => base.clone(),
        };
        feed::drop_disabled(&mut catalog);
        self.catalog = Arc::new(catalog);
        self.base = Arc::new(base);
    }
}

impl Default for CatalogService {
    fn default() -> Self {
        Self::new()
    }
}

impl CatalogService {
    /// The bundled copy, no stored copy, no fetcher.
    pub fn new() -> Self {
        Self::with_bundled(bundled())
    }

    /// Starts from `catalog` as the bundled copy (tests).
    pub fn with_bundled(catalog: Catalog) -> Self {
        let mut in_use = catalog.clone();
        feed::drop_disabled(&mut in_use);
        Self {
            state: Mutex::new(State {
                base: Arc::new(catalog),
                catalog: Arc::new(in_use),
                feed: None,
                feed_etag: None,
                feed_at_ms: None,
                feed_error: None,
                source: Source::Bundled,
                etag: None,
                fetched_at_ms: None,
                last_error: None,
                last_fetch: None,
            }),
            dir: Mutex::new(None),
            fetcher: Mutex::new(None),
            feed_fetcher: Mutex::new(None),
            refreshing: tokio::sync::Mutex::new(()),
            changed: broadcast::channel(16).0,
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Keeps copies in `dir` and fetches with `fetcher` (None: never fetches); loads the
    /// stored copy when it is valid and not older than the one in use.
    pub fn attach(&self, dir: PathBuf, fetcher: Option<Arc<dyn Fetcher>>) {
        let stored = std::fs::read(dir.join(STORE_FILE)).ok().and_then(|bytes| {
            let copy: StoredCopy = serde_json::from_slice(&bytes).ok()?;
            let body = serde_json::to_vec(&copy.catalog).ok()?;
            match schema::parse(&body) {
                Ok(catalog) => Some((catalog, copy)),
                Err(e) => {
                    tracing::warn!("the stored model catalog is not used: {e}");
                    None
                }
            }
        });
        *self.dir.lock().unwrap_or_else(PoisonError::into_inner) = Some(dir);
        *self.fetcher.lock().unwrap_or_else(PoisonError::into_inner) = fetcher;
        if let Some((catalog, copy)) = stored {
            let mut state = self.state();
            // ISO-8601 UTC strings of the same shape order as text.
            if catalog.generated_at >= state.base.generated_at {
                state.set_base(catalog);
                state.source = Source::Stored;
                state.etag = copy.etag;
                state.fetched_at_ms = Some(copy.fetched_at_ms);
            }
        }
    }

    /// Reads the public model feed with `fetcher` on every refresh ([`feed::FeedFetcher`] in the daemon).
    pub fn attach_feed(&self, fetcher: Arc<dyn Fetcher>) {
        *self.feed_fetcher.lock().unwrap_or_else(PoisonError::into_inner) = Some(fetcher);
    }

    /// The catalog in use.
    pub fn current(&self) -> Arc<Catalog> {
        self.state().catalog.clone()
    }

    /// The catalog entry for a harness profile: the entry with its name as id, else one
    /// that lists its family.
    pub fn harness(&self, name: &str, family: &str) -> Option<CatalogHarness> {
        let catalog = self.current();
        let by_id = catalog.harnesses.iter().find(|h| h.id == name);
        by_id
            .or_else(|| catalog.harnesses.iter().find(|h| h.families.iter().any(|f| f == family)))
            .cloned()
    }

    /// `{schemaVersion, generatedAt, source, delivery, fetchedAt?}` of the catalog in use.
    /// `source` is the server's (`live` or `snapshot`); `delivery` is where this daemon got it.
    pub fn summary(&self) -> Value {
        let state = self.state();
        let mut v = json!({"schemaVersion": state.catalog.schema_version, "generatedAt": state.catalog.generated_at, "source": state.catalog.source, "delivery": state.source});
        if let Some(at) = state.fetched_at_ms {
            v.set("fetchedAt", json!(at));
        }
        if let Some(at) = state.feed_at_ms {
            v.set("feedAt", json!(at));
        }
        v
    }

    /// `catalog.get`: the whole document in use and its summary.
    pub fn get(&self) -> Value {
        let mut v = self.summary();
        v.set("catalog", serde_json::to_value(&*self.current()).unwrap_or(Value::Null));
        v
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.changed.subscribe()
    }

    /// Takes a fetched body when it is valid; true when the catalog in use changed.
    fn accept(&self, body: &[u8], etag: Option<String>) -> Result<bool, CatalogError> {
        let catalog = schema::parse(body)?;
        let fetched_at = now_ms();
        let changed = {
            let mut state = self.state();
            let before = state.catalog.clone();
            state.set_base(catalog);
            let changed = *before != *state.catalog;
            state.source = Source::Fetched;
            state.etag = etag.clone();
            state.fetched_at_ms = Some(fetched_at);
            changed
        };
        let dir = self.dir.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(dir) = dir {
            let raw: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
            let copy = StoredCopy { etag, fetched_at_ms: fetched_at, catalog: raw };
            match serde_json::to_vec(&copy) {
                Ok(bytes) => {
                    if let Err(e) = write_atomically(&dir.join(STORE_FILE), &bytes) {
                        tracing::warn!("the model catalog could not be stored: {e}");
                    }
                }
                Err(e) => tracing::warn!("the model catalog could not be stored: {e}"),
            }
        }
        Ok(changed)
    }

    /// Fetches the catalog now. `force` skips [`MIN_FETCH_SPACING`]. Never fails: a fetch error is in `error`.
    pub async fn refresh(&self, force: bool) -> Value {
        let _one = self.refreshing.lock().await;
        let fetcher = self.fetcher.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let recent = self.state().last_fetch.is_some_and(|at| at.elapsed() < MIN_FETCH_SPACING);
        let (changed, error) = match fetcher {
            None => (false, Some("this daemon does not fetch the model catalog".to_owned())),
            Some(_) if recent && !force => (false, self.state().last_error.clone()),
            Some(fetcher) => self.fetch_once(fetcher.as_ref()).await,
        };
        let feed_fetcher = self.feed_fetcher.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let (feed_changed, feed_error) = match feed_fetcher {
            None => (false, None),
            Some(_) if recent && !force => (false, self.state().feed_error.clone()),
            Some(fetcher) => self.fetch_feed_once(fetcher.as_ref()).await,
        };
        let changed = changed || feed_changed;
        let mut reply = self.summary();
        reply.set("changed", json!(changed));
        if let Some(error) = error {
            reply.set("error", json!(error));
        }
        if let Some(error) = feed_error {
            reply.set("feedError", json!(error));
        }
        if changed {
            let _ = self.changed.send(self.summary());
        }
        reply
    }

    async fn fetch_once(&self, fetcher: &dyn Fetcher) -> (bool, Option<String>) {
        let etag = self.state().etag.clone();
        let outcome = fetcher.fetch(etag.as_deref()).await;
        let result = match outcome {
            Ok(FetchOutcome::NotModified) => Ok(false),
            Ok(FetchOutcome::Body { body, etag }) => {
                self.accept(&body, etag).map_err(|e| e.to_string())
            }
            Err(e) => Err(e),
        };
        {
            let mut state = self.state();
            state.last_fetch = Some(std::time::Instant::now());
            state.last_error = result.as_ref().err().cloned();
        }
        // Logged with the state unlocked: a log write can wait (stdout a full pipe), and every
        // request that reads the catalog in use takes this lock (`log_lock_tests.rs`).
        match result {
            Ok(changed) => (changed, None),
            Err(e) => {
                tracing::warn!("model catalog refresh: {e}; keeping the current copy");
                (false, Some(e))
            }
        }
    }

    /// Reads the public feed once; true when the catalog in use changed. The body is parsed off
    /// the async runtime, and only the models of the providers the rules name are kept.
    async fn fetch_feed_once(&self, fetcher: &dyn Fetcher) -> (bool, Option<String>) {
        let (keep, etag) = {
            let state = self.state();
            let keep = feed::providers_used(&state.base);
            // A copy that names a provider the last read did not keep needs the whole feed again.
            let covered = state.feed.as_ref().is_some_and(|f| f.covers(&keep));
            (keep, if covered { state.feed_etag.clone() } else { None })
        };
        let result = match fetcher.fetch(etag.as_deref()).await {
            Ok(FetchOutcome::NotModified) => Ok(None),
            Ok(FetchOutcome::Body { body, etag }) => {
                let parsed = match tokio::runtime::Handle::try_current() {
                    Ok(_) => tokio::task::spawn_blocking(move || feed::parse(&body, &keep))
                        .await
                        .unwrap_or_else(|e| Err(e.to_string())),
                    Err(_) => feed::parse(&body, &keep),
                };
                parsed.map(|snapshot| Some((snapshot, etag)))
            }
            Err(e) => Err(e),
        };
        let (changed, error) = {
            let mut state = self.state();
            let before = state.catalog.clone();
            let error = match result {
                Ok(Some((snapshot, etag))) => {
                    state.feed = Some(Arc::new(snapshot));
                    state.feed_etag = etag;
                    state.feed_at_ms = Some(now_ms());
                    let base = state.base.as_ref().clone();
                    state.set_base(base);
                    None
                }
                Ok(None) => {
                    state.feed_at_ms = Some(now_ms());
                    None
                }
                Err(e) => Some(e),
            };
            state.feed_error = error.clone();
            (*before != *state.catalog, error)
        };
        // Logged with the state unlocked (`log_lock_tests.rs`).
        if let Some(e) = &error {
            tracing::warn!("model feed refresh: {e}; keeping the current models");
        }
        (changed, error)
    }

    /// Fetches at once and then every [`REFRESH_EVERY`], until the task is dropped.
    pub async fn run(self: Arc<Self>) {
        let mut every = tokio::time::interval(REFRESH_EVERY);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            every.tick().await;
            self.refresh(true).await;
        }
    }
}

#[cfg(test)]
#[path = "log_lock_tests.rs"]
mod log_lock_tests;

#[cfg(test)]
#[path = "feed_tests.rs"]
mod feed_tests;
