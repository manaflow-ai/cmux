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
//! data) loses to it. The daemon fetches at start and every 6 h with
//! If-None-Match; `catalog.refresh` fetches now. A body that is too big, not
//! valid, or of a newer major schema version never replaces the current
//! copy. Every change is announced to every connection as `catalog.changed`.

pub mod fetch;
pub mod schema;
#[cfg(test)]
mod tests;

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
/// How often the daemon checks for a new catalog.
pub const REFRESH_EVERY: Duration = Duration::from_secs(6 * 60 * 60);
/// A refresh request within this long of the last network read answers from the current copy.
pub const MIN_FETCH_SPACING: Duration = Duration::from_secs(10);
const STORE_FILE: &str = "models-v1.json";

/// The copy bundled at build time.
pub const BUNDLED: &str = include_str!("../../catalog/models-v1.json");

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
    catalog: Arc<Catalog>,
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
    schema::parse(BUNDLED.as_bytes()).unwrap_or_else(|e| {
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

/// Writes `bytes` to `path` through a temporary file in the same folder, so a reader sees the old or the new file.
fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let dir = path.parent().ok_or_else(|| std::io::Error::other("no parent folder"))?;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{STORE_FILE}.{}.tmp", std::process::id()));
    let result = (|| {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&tmp, path)?;
        std::fs::File::open(dir)?.sync_all()
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
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
        Self {
            state: Mutex::new(State {
                catalog: Arc::new(catalog),
                source: Source::Bundled,
                etag: None,
                fetched_at_ms: None,
                last_error: None,
                last_fetch: None,
            }),
            dir: Mutex::new(None),
            fetcher: Mutex::new(None),
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
            if catalog.generated_at >= state.catalog.generated_at {
                state.catalog = Arc::new(catalog);
                state.source = Source::Stored;
                state.etag = copy.etag;
                state.fetched_at_ms = Some(copy.fetched_at_ms);
            }
        }
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
            v["fetchedAt"] = json!(at);
        }
        v
    }

    /// `catalog.get`: the whole document in use and its summary.
    pub fn get(&self) -> Value {
        let mut v = self.summary();
        v["catalog"] = serde_json::to_value(&*self.current()).unwrap_or(Value::Null);
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
            let changed = *state.catalog != catalog;
            state.catalog = Arc::new(catalog);
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
        let mut reply = self.summary();
        reply["changed"] = json!(changed);
        if let Some(error) = error {
            reply["error"] = json!(error);
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
        let mut state = self.state();
        state.last_fetch = Some(std::time::Instant::now());
        match result {
            Ok(changed) => {
                state.last_error = None;
                (changed, None)
            }
            Err(e) => {
                tracing::warn!("model catalog refresh: {e}; keeping the current copy");
                state.last_error = Some(e.clone());
                (false, Some(e))
            }
        }
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
