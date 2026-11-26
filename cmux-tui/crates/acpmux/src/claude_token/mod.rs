//! One-click Claude Code token (`claude-token` connections; cmux-tui/docs/model-connections.md):
//! the daemon runs `claude setup-token` itself, as its own child in a pty no one sees, so the
//! person never copies a token out of a terminal.
//!
//! `begin` starts the child (`CMUX_CLAUDE_BIN`, else `claude` on the login PATH; no
//! `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`, a `BROWSER` that opens nothing) and answers
//! the sign-in link it prints, which the app opens in its own browser. The sign-in redirects to
//! the child's loopback listener; when the person is shown a code instead, the app hands it to
//! `code`, which types it into the child. The child then prints the token: [`pty::TokenFilter`]
//! takes it out of the output, the [`store::Store`] keeps it (the login Keychain, `cmux-model-key`
//! / `claude-token-<8 hex>`), the connection gets its reference only, and the child's process
//! group is ended. One attempt at a time: a new `begin` cancels the pending one. The token is in
//! no log line, error or reply, and its buffers are zeroized.

pub mod pty;
pub mod store;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
#[cfg(unix)]
use std::os::fd::{AsRawFd as _, OwnedFd};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::{oneshot, watch};
use zeroize::Zeroizing;

pub use crate::chatgpt::{Failure, Status};

/// How long `begin` waits for the sign-in link.
pub const URL_TIMEOUT: Duration = Duration::from_secs(30);
/// How long an attempt waits for the token.
const ATTEMPT_TTL: Duration = Duration::from_secs(15 * 60);
/// How long a finished attempt stays readable by `wait`.
const FINISHED_TTL: Duration = Duration::from_secs(60 * 60);
/// The longest code `code` types.
const CODE_LIMIT: usize = 4096;
/// The Keychain item's label.
const ITEM_LABEL: &str = "cmux Claude Code token";

struct Attempt {
    status: watch::Sender<Status>,
    #[cfg(unix)]
    master: Arc<OwnedFd>,
    stop: Arc<AtomicBool>,
    thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    started: Instant,
}

/// What `begin` answers: the attempt and the sign-in link (`None` when the child printed its
/// token with no link first).
#[derive(Debug, Clone)]
pub struct Begun {
    pub attempt: String,
    pub url: Option<String>,
}

/// The daemon's `claude setup-token` attempts.
pub struct Service {
    store: Arc<dyn store::Store>,
    program: Option<PathBuf>,
    url_timeout: Duration,
    attempts: Mutex<HashMap<String, Arc<Attempt>>>,
}

impl Default for Service {
    fn default() -> Self {
        Self::new(Arc::new(store::Keychain), None, URL_TIMEOUT)
    }
}

#[cfg(unix)]
fn random_id() -> Result<String, Failure> {
    use base64::Engine as _;
    let mut buf = [0u8; 18];
    getrandom::fill(&mut buf).map_err(|e| Failure::new("internal", e.to_string()))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(buf))
}

#[cfg(unix)]
/// The last line of what the child showed, for an error (it is never the token: the filter took
/// that out first).
fn last_line(shown: &[u8]) -> String {
    let text = pty::strip_ansi(shown);
    let text = String::from_utf8_lossy(&text);
    let line = text
        .split(['\r', '\n'])
        .map(str::trim)
        .rfind(|l| !l.is_empty() && l.chars().any(char::is_alphanumeric))
        .unwrap_or_default();
    line.chars().take(200).collect()
}

#[cfg(unix)]
/// What a finished read of the child ends in.
enum Read {
    Token(Zeroizing<String>),
    Failed(Failure),
}

impl Service {
    /// A service that stores tokens in `store` and runs `program` (`None`: [`pty::program`]),
    /// waiting `url_timeout` for the link.
    pub fn new(
        store: Arc<dyn store::Store>,
        program: Option<PathBuf>,
        url_timeout: Duration,
    ) -> Self {
        Self { store, program, url_timeout, attempts: Mutex::new(HashMap::new()) }
    }

    /// Starts `claude setup-token` and answers its sign-in link. `add` turns the stored token's
    /// reference into a connection (its id); a refused add deletes the stored item. `on_finish`
    /// runs once the attempt ends. Both run on the attempt's own thread, inside this runtime.
    pub async fn begin(
        self: &Arc<Self>,
        add: impl FnOnce(&str) -> Result<String, Failure> + Send + 'static,
        on_finish: impl FnOnce(&Status) + Send + 'static,
    ) -> Result<Begun, Failure> {
        let pending_ids: Vec<String> = self
            .attempts
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .iter()
            .filter(|(_, a)| *a.status.borrow() == Status::Pending)
            .map(|(id, _)| id.clone())
            .collect();
        for id in pending_ids {
            let _ = self.cancel(&id).await;
        }
        self.prune();
        #[cfg(not(unix))]
        {
            let _ = (add, on_finish);
            return Err(Failure::new(
                "unsupported",
                "a Claude Code token needs a unix build of acpmux",
            ));
        }
        #[cfg(unix)]
        self.spawn_child(add, on_finish).await
    }

    /// [`Self::begin`]'s child: `claude setup-token` in a new pty, read on its own thread.
    #[cfg(unix)]
    async fn spawn_child(
        self: &Arc<Self>,
        add: impl FnOnce(&str) -> Result<String, Failure> + Send + 'static,
        on_finish: impl FnOnce(&Status) + Send + 'static,
    ) -> Result<Begun, Failure> {
        let program = self.program.clone().unwrap_or_else(pty::program);
        let (master, slave, slave_path) =
            pty::open_pty(pty::MIN_COLUMNS.max(240)).map_err(|e| Failure::new("pty", e))?;
        let spawned = pty::command(&program, &slave_path, true).spawn();
        drop(slave);
        let mut child = spawned.map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                Failure::new(
                    "no_claude",
                    format!("{} is not installed: install Claude Code first", program.display()),
                )
            } else {
                Failure::new("spawn", format!("cannot start {}: {error}", program.display()))
            }
        })?;
        let attempt = match random_id() {
            Ok(id) => id,
            Err(failure) => {
                pty::stop(&mut child);
                let _ = child.wait();
                return Err(failure);
            }
        };
        let (status, _) = watch::channel(Status::Pending);
        let entry = Arc::new(Attempt {
            status,
            master: Arc::new(master),
            stop: Arc::new(AtomicBool::new(false)),
            thread: Mutex::new(None),
            started: Instant::now(),
        });
        self.attempts
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(attempt.clone(), entry.clone());
        let (url_tx, url_rx) = oneshot::channel();
        let runtime = tokio::runtime::Handle::current();
        let store = self.store.clone();
        let url_timeout = self.url_timeout;
        let task_entry = entry.clone();
        let thread = std::thread::Builder::new()
            .name("claude setup-token".into())
            .spawn(move || {
                let mut url_tx = Some(url_tx);
                let read = read_token(&task_entry, url_timeout, &mut url_tx);
                pty::stop(&mut child);
                let _ = child.wait();
                let _runtime = runtime.enter();
                let status = match read {
                    Read::Token(token) => match keep(&*store, token, add) {
                        Ok(id) => Status::Done(id),
                        Err(failure) => {
                            tracing::info!(code = %failure.code, "Claude token: {}", failure.message);
                            Status::Failed(failure.code)
                        }
                    },
                    Read::Failed(failure) => {
                        tracing::info!(code = %failure.code, "Claude token: {}", failure.message);
                        let status = if failure.code == "cancelled" {
                            Status::Cancelled
                        } else {
                            Status::Failed(failure.code.clone())
                        };
                        if let Some(tx) = url_tx.take() {
                            let _ = tx.send(Err(failure));
                        }
                        status
                    }
                };
                // A cancel that came first keeps its own status.
                task_entry.status.send_if_modified(|s| {
                    let pending = *s == Status::Pending;
                    if pending {
                        *s = status.clone();
                    }
                    pending
                });
                let finished = task_entry.status.borrow().clone();
                on_finish(&finished);
            })
            .map_err(|e| Failure::new("spawn", e.to_string()))?;
        *entry.thread.lock().unwrap_or_else(|p| p.into_inner()) = Some(thread);
        match url_rx.await {
            Ok(Ok(url)) => Ok(Begun { attempt, url }),
            Ok(Err(failure)) => Err(failure),
            Err(_) => Err(Failure::new("internal", "the attempt ended without an answer")),
        }
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
            .ok_or_else(|| Failure::new("unknown_attempt", "no such Claude token attempt"))
    }

    /// The attempt's status once it is no longer pending, or after `timeout`.
    pub async fn wait(&self, attempt: &str, timeout: Duration) -> Result<Status, Failure> {
        let mut rx = self.attempt(attempt)?.status.subscribe();
        let _ = tokio::time::timeout(timeout, rx.wait_for(|s| *s != Status::Pending)).await;
        let status = rx.borrow().clone();
        Ok(status)
    }

    /// Types `code` (every whitespace character taken out) and Return into a pending attempt's
    /// child, for a sign-in that shows a code to paste back.
    pub async fn code(&self, attempt: &str, code: &str) -> Result<(), Failure> {
        let entry = self.attempt(attempt)?;
        let code: Zeroizing<String> =
            Zeroizing::new(code.chars().filter(|c| !c.is_whitespace()).collect());
        if code.is_empty() || code.len() > CODE_LIMIT || code.chars().any(char::is_control) {
            return Err(Failure::new("bad_code", "the code is empty, too long or not text"));
        }
        if *entry.status.borrow() != Status::Pending {
            return Err(Failure::new("not_pending", "the attempt already ended"));
        }
        #[cfg(not(unix))]
        let written = false;
        #[cfg(unix)]
        let master = entry.master.clone();
        #[cfg(unix)]
        let written = tokio::task::spawn_blocking(move || {
            let fd = master.as_raw_fd();
            // Return on its own, a moment later: a terminal UI reads one chunk as a paste.
            let typed = pty::write_all(fd, code.as_bytes());
            std::thread::sleep(Duration::from_millis(150));
            typed && pty::write_all(fd, b"\r")
        })
        .await
        .unwrap_or(false);
        if written {
            Ok(())
        } else {
            Err(Failure::new("not_pending", "the child no longer reads its terminal"))
        }
    }

    /// Ends a pending attempt; its child is gone when this returns.
    pub async fn cancel(&self, attempt: &str) -> Result<Status, Failure> {
        let entry = self.attempt(attempt)?;
        let current = entry.status.borrow().clone();
        if current != Status::Pending {
            return Ok(current);
        }
        entry.stop.store(true, Ordering::SeqCst);
        let thread = entry.thread.lock().unwrap_or_else(|p| p.into_inner()).take();
        if let Some(thread) = thread {
            let _ = tokio::task::spawn_blocking(move || thread.join()).await;
        }
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
}

#[cfg(unix)]
/// The child's output until its token: the link goes to `url_tx` once it is whole (within
/// `url_timeout`), then the token is read (within [`ATTEMPT_TTL`]). It looks for a cancel every
/// 100 ms.
fn read_token(
    entry: &Attempt,
    url_timeout: Duration,
    url_tx: &mut Option<oneshot::Sender<Result<Option<String>, Failure>>>,
) -> Read {
    let fd = entry.master.as_raw_fd();
    let started = Instant::now();
    let mut filter = pty::TokenFilter::default();
    // What the child showed (never the token), the last 64 KiB.
    let mut shown: Vec<u8> = Vec::new();
    let mut buf = Zeroizing::new(vec![0u8; 8192]);
    loop {
        if entry.stop.load(Ordering::SeqCst) {
            return Read::Failed(Failure::new("cancelled", "the attempt was cancelled"));
        }
        if url_tx.is_some() && started.elapsed() >= url_timeout {
            return Read::Failed(Failure::new(
                "no_url",
                format!("claude setup-token showed no sign-in link: {}", last_line(&shown)),
            ));
        }
        if started.elapsed() >= ATTEMPT_TTL {
            return Read::Failed(Failure::new("timeout", "no token after 15 minutes"));
        }
        let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        // SAFETY: one pollfd of ours.
        if unsafe { libc::poll(&mut poll, 1, 100) } <= 0 {
            continue;
        }
        // SAFETY: reads into our own buffer from our own fd.
        let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
        if n < 0
            && matches!(
                std::io::Error::last_os_error().kind(),
                std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
            )
        {
            continue;
        }
        if n <= 0 {
            break;
        }
        let out = filter.push(buf.get(..n as usize).unwrap_or_default());
        shown.extend_from_slice(&out);
        if shown.len() > 64 * 1024 {
            shown.drain(..shown.len() - 64 * 1024);
        }
        if url_tx.is_some()
            && let Some(url) = pty::find_url(&shown)
            && let Some(tx) = url_tx.take()
        {
            let _ = tx.send(Ok(Some(url)));
        }
        if filter.done() {
            break;
        }
    }
    let (rest, token) = filter.finish();
    shown.extend_from_slice(&rest);
    match token {
        Some(token) if token.len() >= pty::MIN_TOKEN => {
            if let Some(tx) = url_tx.take() {
                let _ = tx.send(Ok(None));
            }
            Read::Token(token)
        }
        Some(_) => Read::Failed(Failure::new("cut_short", "the token was cut short")),
        None if url_tx.is_some() => Read::Failed(Failure::new(
            "no_url",
            format!("claude setup-token ended with no sign-in link: {}", last_line(&shown)),
        )),
        None => Read::Failed(Failure::new(
            "no_token",
            format!("claude setup-token ended without a token: {}", last_line(&shown)),
        )),
    }
}

#[cfg(unix)]
/// `token` into `store`, then `add` with its reference; a refused add deletes the item.
fn keep(
    store: &dyn store::Store,
    token: Zeroizing<String>,
    add: impl FnOnce(&str) -> Result<String, Failure>,
) -> Result<String, Failure> {
    let (reference, account) =
        store.store(ITEM_LABEL, &token).map_err(|e| Failure::new("store", e))?;
    drop(token);
    add(&reference).inspect_err(|_| store.delete(&account))
}
