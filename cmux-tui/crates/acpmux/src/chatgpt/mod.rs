//! Sign in with ChatGPT (`chatgpt-plan` connections; cmux-tui/docs/model-connections.md), from
//! OpenAI's documented open-source token-sharing protocol (no DevKit code: its license is
//! noncommercial).
//!
//! `begin` registers this installation (`client_id=dynamic_agent_client` the first time, the
//! issued `oaiapp_...` id afterwards), starts a `127.0.0.1:<ephemeral>/auth/callback` listener
//! and answers the authorize URL, which the app opens in the person's browser. The callback
//! checks `state`, records an issued client id before the code exchange, exchanges the code with
//! PKCE (S256), validates the ID token (JWKS from the OpenID configuration; `iss`, `aud`, `exp`,
//! `nonce`), requires the `chatgpt.tokens.use.direct` scope, and stores the account
//! (`store.rs`) with a `chatgpt-plan` route. `token` hands the gateway an access token,
//! refreshing it under 5 minutes left, one refresh per account at a time. `remove` revokes the
//! refresh token. No token reaches a log line or an error message.
//!
//! Every OAuth URL comes from [`Endpoints`], so tests run the whole flow against a local server.

mod jwt;
mod oauth;
pub(crate) mod store;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::watch;

pub use oauth::Endpoints;

/// The client id of a first registration; never stored.
pub const DYNAMIC_CLIENT_ID: &str = "dynamic_agent_client";
/// The scope a ChatGPT plan's tokens must carry to be used directly.
pub const PLAN_SCOPE: &str = "chatgpt.tokens.use.direct";
/// The scopes asked for.
pub const SCOPES: &str =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
/// The resource every token is for, and a `chatgpt-plan` route's base URL.
pub const RESOURCE: &str = "https://api.openai.com/v1";
/// How long an access token must still be good for `token` to hand it out unrefreshed.
pub const REFRESH_MARGIN_SECS: i64 = 300;
/// How long a token `_acpmux/connections/credential` hands a Cloud machine must still be good for.
pub const CREDENTIAL_MARGIN_SECS: i64 = 600;
/// How long a sign-in waits for its callback.
const ATTEMPT_TTL: Duration = Duration::from_secs(15 * 60);
/// How long a finished attempt stays readable by `wait`.
const FINISHED_TTL: Duration = Duration::from_secs(60 * 60);

/// A sign-in or token failure: a stable `code` (`access_denied`, `no_plan_scope`, ...) the app
/// shows, and a message with no token in it.
#[derive(Debug, Clone, PartialEq)]
pub struct Failure {
    pub code: String,
    pub message: String,
}

impl Failure {
    pub(crate) fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.to_owned(), message: message.into() }
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
    Cancelled,
}

impl Status {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Done(_) => "done",
            Self::Failed(_) => "failed",
            Self::Cancelled => "cancelled",
        }
    }
}

struct Attempt {
    status: watch::Sender<Status>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
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
    refreshing: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

impl Default for Service {
    fn default() -> Self {
        Self::new(Endpoints::openai())
    }
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn io(code: &str) -> impl Fn(std::io::Error) -> Failure + '_ {
    move |e| Failure::new(code, e.to_string())
}

impl Service {
    pub fn new(endpoints: Endpoints) -> Self {
        Self {
            oauth: oauth::Client::new(endpoints),
            attempts: Mutex::new(HashMap::new()),
            refreshing: Mutex::new(HashMap::new()),
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
        let home = places.home.clone();
        let host = tokio::task::spawn_blocking(move || store::host(&home))
            .await
            .map_err(|e| Failure::new("internal", e.to_string()))?
            .map_err(io("storage"))?;
        let prior = match &reauth {
            Some(id) => {
                Some(store::read(&places.home, id).map_err(io("storage"))?.ok_or_else(|| {
                    Failure::new("not_found", format!("no ChatGPT sign-in {id:?}"))
                })?)
            }
            None => None,
        };
        let listener =
            tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.map_err(io("listener"))?;
        let port = listener.local_addr().map_err(io("listener"))?.port();
        let pending = oauth::Pending::new(host, port, reauth, prior.as_ref())?;
        let url = self.oauth.authorize_url(&pending)?;
        let attempt = oauth::random_token(18)?;
        self.prune();
        let (status, _) = watch::channel(Status::Pending);
        let entry = Arc::new(Attempt { status, task: Mutex::new(None), started: Instant::now() });
        self.attempts
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(attempt.clone(), entry.clone());
        let service = self.clone();
        let task_entry = entry.clone();
        let task = tokio::spawn(async move {
            let outcome = tokio::time::timeout(
                ATTEMPT_TTL,
                service.oauth.serve_callback(listener, &pending, &places),
            )
            .await;
            let status = match outcome {
                Ok(Ok(id)) => Status::Done(id),
                Ok(Err(failure)) => {
                    tracing::info!(code = %failure.code, "ChatGPT sign-in failed: {}", failure.message);
                    Status::Failed(failure.code)
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

    fn attempt(&self, id: &str) -> Result<Arc<Attempt>, Failure> {
        self.attempts
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(id)
            .cloned()
            .ok_or_else(|| Failure::new("unknown_attempt", "no such sign-in attempt"))
    }

    /// The attempt's status once it is no longer pending, or after `timeout`.
    pub async fn wait(&self, attempt: &str, timeout: Duration) -> Result<Status, Failure> {
        let mut rx = self.attempt(attempt)?.status.subscribe();
        let _ = tokio::time::timeout(timeout, rx.wait_for(|s| *s != Status::Pending)).await;
        let status = rx.borrow().clone();
        Ok(status)
    }

    /// Ends a pending attempt; its listener is closed when this returns.
    pub async fn cancel(&self, attempt: &str) -> Result<Status, Failure> {
        let entry = self.attempt(attempt)?;
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
        let mut record = store::read(home, id)
            .map_err(io("storage"))?
            .ok_or_else(|| Failure::new("not_found", format!("no ChatGPT sign-in {id:?}")))?;
        if !record.signed_in() {
            return Err(Failure::new("signed_out", "sign in with ChatGPT again"));
        }
        if !record.access_token.is_empty() && record.expires_at - now_unix() > margin {
            return Ok((record.access_token, record.expires_at));
        }
        match self.oauth.refresh(&record).await {
            Ok(fresh) => {
                fresh.apply(&mut record, now_unix());
                store::write(home, id, &record).map_err(io("storage"))?;
                Ok((record.access_token, record.expires_at))
            }
            Err(failure) => {
                if failure.code == "reauth_required" {
                    // The refresh token is dead: the account shows signed out until a reauth.
                    record.clear_tokens();
                    store::write(home, id, &record).map_err(io("storage"))?;
                }
                Err(failure)
            }
        }
    }

    /// Signs account `id` out: revokes its refresh token (best effort: a revocation that fails
    /// still clears the tokens here) and deletes its record. The host id and client id stay.
    /// True when the revocation succeeded.
    pub async fn remove(&self, home: &Path, id: &str) -> Result<bool, Failure> {
        let lock = self.lock_for(id);
        let _one = lock.lock().await;
        let Some(record) = store::read(home, id).map_err(io("storage"))? else {
            return Ok(false);
        };
        let revoked = if record.signed_in() {
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
        store::delete(home, id).map_err(io("storage"))?;
        Ok(revoked)
    }
}
