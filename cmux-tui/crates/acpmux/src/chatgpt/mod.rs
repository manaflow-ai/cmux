//! Sign in with ChatGPT (`chatgpt-plan` connections; cmux-tui/docs/model-connections.md): the
//! same ChatGPT sign-in Codex itself runs (`codex login`, cmux#45774), so a Cloud chat's Codex
//! runs on the person's ChatGPT plan through the ChatGPT Codex backend, as it does on their Mac.
//! (OpenAI's separate token-sharing protocol, `chatgpt.tokens.use.direct` on api.openai.com,
//! refuses most accounts with `subscription_sharing_user_not_eligible`; cmux no longer uses it.)
//!
//! `begin` starts a `127.0.0.1:1455/auth/callback` listener (the redirect Codex's OAuth client is
//! registered with; 1457 when another program holds 1455, and a `/cancel` from `codex login` ends it) and answers the authorize URL, which the app opens in the person's browser.
//! The callback checks `state`, exchanges the code with PKCE (S256), validates the ID token (JWKS
//! from the OpenID configuration; `iss`, `aud`, `exp`), requires the ChatGPT account the tokens
//! act for, and stores the account (`store.rs`) with a `chatgpt-plan` route. The daemon owns this
//! login: it is never the Mac's `~/.codex`, so refreshing it (Codex rotates refresh tokens) never
//! signs the person out of Codex. `token` hands out an access token, refreshing it under 5 minutes
//! left, one refresh per account at a time. `remove` revokes the refresh token. No token reaches
//! a log line or an error message.
//!
//! Cloud Settings starts a device code through `begin_device` and uses the same account store.
//! Every OAuth URL comes from [`Endpoints`], so tests run the whole flow against a local server.

mod import;
mod device;
mod jwt;
pub(crate) mod oauth;
pub(crate) mod store;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::watch;

use crate::routes::{self, RouteKind};

pub(crate) use import::codex_auth as import_codex_auth;
#[cfg(test)]
pub(crate) use import::test_auth_json as import_test_auth;
pub use import::{ENV as CI_IMPORT_ENV, enabled as ci_import_enabled};
pub use device::DeviceBegun;
pub use oauth::Endpoints;

/// Codex's OAuth client (the one `codex login` signs in with).
pub const CODEX_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
/// The loopback port Codex's client is registered to redirect to.
pub const CALLBACK_PORT: u16 = 1455;
/// Codex's registered fallback port, used when [`CALLBACK_PORT`] is held by another program.
pub const CALLBACK_FALLBACK_PORT: u16 = 1457;
/// The scopes asked for: Codex's own.
pub const SCOPES: &str =
    "openid profile email offline_access api.connectors.read api.connectors.invoke";
/// The scopes a refresh asks for (Codex's refresh request).
pub const REFRESH_SCOPES: &str = "openid profile email";
/// Where a `chatgpt-plan` connection's Codex sends its turns: the ChatGPT Codex backend, a
/// `chatgpt-plan` route's base URL.
pub const CODEX_BACKEND: &str = "https://chatgpt.com/backend-api/codex";
/// How long an access token must still be good for `token` to hand it out unrefreshed.
pub const REFRESH_MARGIN_SECS: i64 = 300;
/// Spawn metadata for a token obtained from this daemon's ChatGPT store.
pub(crate) const LOCAL_EXPIRY_ENV: &str = "ACPMUX_LOCAL_CHATGPT_EXPIRY";
/// How long a token `_acpmux/connections/credential` hands a Cloud machine must still be good for.
pub const CREDENTIAL_MARGIN_SECS: i64 = 600;
/// How long a sign-in waits for its callback.
const ATTEMPT_TTL: Duration = Duration::from_secs(15 * 60);
/// How long a finished attempt stays readable by `wait`.
const FINISHED_TTL: Duration = Duration::from_secs(60 * 60);

/// The owner of every sign-in attempt's callback task; an attempt's cancel aborts its own.
fn sign_in_scope() -> &'static cmux_scope::Scope {
    static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("chatgpt sign-in"))
}

/// A sign-in or token failure: a stable `code` (`access_denied`, `no_chatgpt_account`, ...) the app
/// shows, and a message with no token in it.
#[derive(Debug, Clone, PartialEq)]
pub struct Failure {
    pub code: String,
    pub message: String,
    accounts: Option<(String, String)>,
}

impl Failure {
    pub(crate) fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.to_owned(), message: message.into(), accounts: None }
    }

    fn wrong_account(actual: String, expected: String) -> Self {
        Self { code: "different_account".into(), message: "ChatGPT approved a different account".into(),
            accounts: Some((actual, expected)) }
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

/// Where a sign-in writes: the route folder and the acpmux home (`routes::places`).
#[derive(Debug, Clone)]
pub struct Places {
    pub routes: Option<PathBuf>,
    pub home: PathBuf,
}

/// A sign-in attempt's state, as `chatgpt.wait` answers it.
#[derive(Debug, Clone, PartialEq)]
pub enum Status {
    Pending,
    /// Signed in: the connection's route id.
    Done(String),
    Failed(String),
    WrongAccount { actual: String, expected: String },
    Cancelled,
}

impl Status {
    fn failed(failure: Failure) -> Self {
        match failure.accounts {
            Some((actual, expected)) => Self::WrongAccount { actual, expected },
            None => Self::Failed(failure.code),
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Done(_) => "done",
            Self::Failed(_) | Self::WrongAccount { .. } => "failed",
            Self::Cancelled => "cancelled",
        }
    }
}

struct Attempt {
    status: watch::Sender<Status>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    device_cancel: Option<watch::Sender<bool>>,
    device_request: Option<(PathBuf, Option<String>, DeviceBegun)>,
    started: Instant,
}

/// What `begin` answers.
#[derive(Debug, Clone)]
pub struct Begun {
    pub attempt: String,
    pub url: String,
}

/// The daemon's Sign in with ChatGPT: its sign-in attempts and the one-refresh-per-account locks.
pub struct Service {
    oauth: oauth::Client,
    attempts: Mutex<HashMap<String, Arc<Attempt>>>,
    device_begin: tokio::sync::Mutex<()>,
    refreshing: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    pending_writes: Mutex<HashMap<(PathBuf, String), PendingWrite>>,
}

impl Default for Service {
    fn default() -> Self {
        Self::new(Endpoints::openai())
    }
}

#[derive(Clone)]
struct PendingWrite {
    previous: store::Record,
    current: store::Record,
}

pub(crate) fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn io(code: &str) -> impl Fn(std::io::Error) -> Failure + '_ {
    move |e| Failure::new(code, e.to_string())
}

fn store_failure(error: crate::subscription_store::Error) -> Failure {
    Failure::new(error.code(), error.message())
}

async fn store_work<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, crate::subscription_store::Error> + Send + 'static,
) -> Result<T, Failure> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|_| Failure::new("storage", "subscription storage worker stopped"))?
        .map_err(store_failure)
}

/// Whether route `id` in `dir` is a Sign in with ChatGPT connection.
pub(crate) fn is_chatgpt_route(dir: Option<&Path>, id: &str) -> bool {
    routes::find(dir, id).is_ok_and(|r| r.file.kind == RouteKind::ChatgptPlan)
}

impl Service {
    pub fn new(endpoints: Endpoints) -> Self {
        Self {
            oauth: oauth::Client::new(endpoints),
            attempts: Mutex::new(HashMap::new()),
            device_begin: tokio::sync::Mutex::new(()),
            refreshing: Mutex::new(HashMap::new()),
            pending_writes: Mutex::new(HashMap::new()),
        }
    }

    fn lock_for(&self, id: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut map = self.refreshing.lock().unwrap_or_else(|p| p.into_inner());
        map.entry(id.to_owned()).or_default().clone()
    }

    /// Starts a sign-in (`reauth`: the route id of an account to sign in again). The callback
    /// listener is bound before this returns. `on_finish` runs once the attempt ends.
    pub async fn begin(
        self: &Arc<Self>,
        places: Places,
        reauth: Option<String>,
        on_finish: impl FnOnce(&Status) + Send + 'static,
    ) -> Result<Begun, Failure> {
        // A route with no sign-in in this home (the route folder is every cmux's on the Mac, the
        // record is this acpmux's; another build or the retired token-sharing client wrote it) reads
        // signed out, and signing in again there signs in on that route (cmux#45774).
        let prior = match &reauth {
            Some(id) => match store::metadata(&places.home, id) {
                Some(record) => Some(record),
                None if is_chatgpt_route(places.routes.as_deref(), id) => None,
                None => {
                    return Err(Failure::new("not_found", format!("no ChatGPT sign-in {id:?}")));
                }
            },
            None => None,
        };
        // Codex's client redirects only to its registered loopback port: a newer sign-in ends any
        // pending one first, and a port another program (`codex login`) holds is said, not waited on.
        let pending_ids: Vec<String> = self
            .attempts
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .iter()
            .filter(|(_, a)| a.device_cancel.is_none() && *a.status.borrow() == Status::Pending)
            .map(|(id, _)| id.clone())
            .collect();
        for id in pending_ids {
            let _ = self.cancel(&id).await;
        }
        let primary = self.oauth.endpoints.callback_port;
        let listener = match tokio::net::TcpListener::bind(("127.0.0.1", primary)).await {
            Ok(listener) => listener,
            // Port 0 (tests) never fails to bind; a real one falls back to Codex's second port.
            Err(_) if primary != 0 => {
                tokio::net::TcpListener::bind(("127.0.0.1", CALLBACK_FALLBACK_PORT)).await.map_err(
                    |e| {
                        Failure::new(
                            "port_busy",
                            format!("another program holds both ChatGPT callback ports: {e}"),
                        )
                    },
                )?
            }
            Err(e) => return Err(Failure::new("port_busy", e.to_string())),
        };
        let port = listener.local_addr().map_err(io("listener"))?.port();
        let pending = oauth::Pending::new(port, reauth, prior.as_ref())?;
        let url = self.oauth.authorize_url(&pending)?;
        let attempt = oauth::random_token(18)?;
        self.prune();
        let (status, _) = watch::channel(Status::Pending);
        let entry = Arc::new(Attempt {
            status,
            task: Mutex::new(None),
            device_cancel: None,
            device_request: None,
            started: Instant::now(),
        });
        self.attempts
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(attempt.clone(), entry.clone());
        let service = self.clone();
        let task_entry = entry.clone();
        let task = sign_in_scope().spawn_named("chatgpt sign-in callback", async move {
            let outcome = tokio::time::timeout(
                ATTEMPT_TTL,
                service.oauth.serve_callback(listener, &pending, &places),
            )
            .await;
            let status = match outcome {
                Ok(Ok(id)) => Status::Done(id),
                Ok(Err(failure)) => {
                    tracing::info!(code = %failure.code, "ChatGPT sign-in failed: {}", failure.message);
                    Status::failed(failure)
                }
                Err(_) => Status::Failed("timeout".into()),
            };
            task_entry.status.send_replace(status.clone());
            on_finish(&status);
        });
        *entry.task.lock().unwrap_or_else(|p| p.into_inner()) = Some(task);
        Ok(Begun { attempt, url })
    }

    fn prune(&self) {
        let mut map = self.attempts.lock().unwrap_or_else(|p| p.into_inner());
        map.retain(|_, a| {
            *a.status.borrow() == Status::Pending || a.started.elapsed() < FINISHED_TTL
        });
    }

    fn attempt(&self, id: &str, device: bool) -> Result<Arc<Attempt>, Failure> {
        self.attempts
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(id)
            .filter(|entry| entry.device_cancel.is_some() == device)
            .cloned()
            .ok_or_else(|| Failure::new("unknown_attempt", "no such sign-in attempt"))
    }

    /// The attempt's status once it is no longer pending, or after `timeout`.
    pub async fn wait(&self, attempt: &str, timeout: Duration) -> Result<Status, Failure> {
        self.wait_for(attempt, timeout, false).await
    }

    pub async fn wait_device(&self, attempt: &str, timeout: Duration) -> Result<Status, Failure> {
        self.wait_for(attempt, timeout, true).await
    }

    async fn wait_for(
        &self,
        attempt: &str,
        timeout: Duration,
        device: bool,
    ) -> Result<Status, Failure> {
        let mut rx = self.attempt(attempt, device)?.status.subscribe();
        let _ = tokio::time::timeout(timeout, rx.wait_for(|s| *s != Status::Pending)).await;
        let status = rx.borrow().clone();
        Ok(status)
    }

    /// Ends a pending attempt; its listener is closed when this returns.
    pub async fn cancel(&self, attempt: &str) -> Result<Status, Failure> {
        let entry = self.attempt(attempt, false)?;
        let current = entry.status.borrow().clone();
        if current != Status::Pending {
            return Ok(current);
        }
        let task = entry.task.lock().unwrap_or_else(|p| p.into_inner()).take();
        if let Some(task) = task {
            task.abort();
            // Aborted (or finished just now): either way its listener is dropped.
            let _ = task.await;
        }
        // A sign-in that finished while this ran keeps its own status.
        entry.status.send_if_modified(|s| {
            let pending = *s == Status::Pending;
            if pending {
                *s = Status::Cancelled;
            }
            pending
        });
        let status = entry.status.borrow().clone();
        Ok(status)
    }

    /// An access token for account `id` good for at least [`REFRESH_MARGIN_SECS`], refreshed
    /// when needed. One refresh per account at a time: concurrent callers wait for it and
    /// read its result.
    pub async fn token(&self, home: &Path, id: &str) -> Result<(String, i64), Failure> {
        self.token_lasting(home, id, REFRESH_MARGIN_SECS).await
    }

    /// `token`, good for at least `margin` seconds (a machine launch asks for
    /// [`CREDENTIAL_MARGIN_SECS`]).
    pub async fn token_lasting(
        &self,
        home: &Path,
        id: &str,
        margin: i64,
    ) -> Result<(String, i64), Failure> {
        let lock = self.lock_for(id);
        let _one = lock.lock().await;
        let key = (home.to_owned(), id.to_owned());
        let read = || async {
            let (home, id) = key.clone();
            store_work(move || store::read(&home, &id))
                .await?
                .ok_or_else(|| Failure::new("signed_out", "sign in with ChatGPT again"))
        };
        let mut observed = read().await;
        loop {
            let pending = self.pending_writes.lock().unwrap_or_else(|p| p.into_inner()).get(&key).cloned();
            if let Some(pending) = pending {
                let _save = self.oauth.save_slot().await;
                observed = read().await;
                match &observed {
                    Ok(stored) if stored == &pending.previous || stored == &pending.current => {
                        if let Err(error) = self.persist(&key, &pending.current, _save).await {
                            return live_token(pending.current).ok_or(error);
                        }
                        self.pending_writes.lock().unwrap_or_else(|p| p.into_inner()).remove(&key);
                        if let Some(token) = live_token(pending.current.clone()) {
                            return Ok(token);
                        }
                        observed = Ok(pending.current);
                    }
                    Err(error) if error.code != "signed_out" => {
                        return live_token(pending.current).ok_or_else(|| error.clone());
                    }
                    _ => {}
                }
                self.pending_writes.lock().unwrap_or_else(|p| p.into_inner()).remove(&key);
            }
            let record = observed?;
            if !record.signed_in() {
                return Err(Failure::new("signed_out", "sign in with ChatGPT again"));
            }
            if !record.access_token.is_empty() && record.expires_at.saturating_sub(now_unix()) > margin {
                return Ok((record.access_token, record.expires_at));
            }
            match self.oauth.refresh(&record).await {
                Ok(fresh) => {
                    let mut current = record.clone();
                    fresh.apply(&mut current, now_unix());
                    // Save the rotated grant before the next await. A cancelled caller
                    // cannot remove it before a later request retries the pending write.
                    self.pending_writes.lock().unwrap_or_else(|p| p.into_inner()).insert(
                        key.clone(), PendingWrite { previous: record.clone(), current },
                    );
                    observed = Ok(record);
                }
                Err(failure) => {
                    let _save = self.oauth.save_slot().await;
                    let current = read().await?;
                    if current != record {
                        // An interactive sign-in finished while the refresh was in flight.
                        observed = Ok(current);
                        continue;
                    }
                    if failure.code == "reauth_required" {
                        let mut cleared = record;
                        cleared.clear_tokens();
                        self.persist(&key, &cleared, _save).await?;
                        return Err(failure);
                    }
                    return live_token(record).ok_or(failure);
                }
            }
        }
    }

    async fn persist(
        &self, key: &(PathBuf, String), record: &store::Record,
        save: tokio::sync::OwnedMutexGuard<()>,
    ) -> Result<(), Failure> {
        let (home, id) = key.clone();
        let record = record.clone();
        store_work(move || {
            let _save = save;
            store::write(&home, &id, &record)
        }).await
    }

    /// Signs account `id` out: revokes its refresh token (best effort: a revocation that fails
    /// still clears the tokens here) and deletes its record.
    /// True when the revocation succeeded.
    pub async fn remove(&self, home: &Path, id: &str) -> Result<bool, Failure> {
        let lock = self.lock_for(id);
        let _one = lock.lock().await;
        let _save = self.oauth.save_slot().await;
        let key = (home.to_owned(), id.to_owned());
        let (path, route) = key.clone();
        let stored = store_work(move || store::read(&path, &route)).await.ok().flatten();
        let record = stored.map(|stored| {
            self.pending_writes.lock().unwrap_or_else(|p| p.into_inner()).get(&key)
                .filter(|pending| pending.previous == stored || pending.current == stored)
                .map_or(stored, |pending| pending.current.clone())
        });
        let (path, route) = key.clone();
        store_work(move || {
            let _save = _save;
            store::delete(&path, &route)
        }).await?;
        self.pending_writes.lock().unwrap_or_else(|p| p.into_inner()).remove(&key);
        let revoked = if let Some(record) = record.filter(store::Record::signed_in) {
            match self.oauth.revoke(&record).await {
                Ok(()) => true,
                Err(failure) => {
                    tracing::warn!(route = %id, code = %failure.code, "ChatGPT revocation failed: {}", failure.message);
                    false
                }
            }
        } else {
            false
        };
        Ok(revoked)
    }
}

fn live_token(record: store::Record) -> Option<(String, i64)> {
    (!record.access_token.is_empty() && record.expires_at > now_unix())
        .then_some((record.access_token, record.expires_at))
}
