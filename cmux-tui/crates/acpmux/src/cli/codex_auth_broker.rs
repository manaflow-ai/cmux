//! Private-pipe Codex auth owner. This process alone runs managed Codex
//! against its dedicated home. Consumers receive access tokens, never the
//! refresh token or auth.json. The native owner must authorize each VM before
//! forwarding a reply; this command exposes no network listener.
//!
//! https://learn.chatgpt.com/docs/auth/ci-cd-auth: keep one auth.json holder,
//! let Codex refresh it, and preserve its writeback. External-token clients
//! use https://learn.chatgpt.com/docs/app-server#auth-endpoints instead.

use anyhow::{Result, anyhow, ensure};
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::fs::File;
use std::io::{IsTerminal, Read};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio_util::codec::{FramedRead, FramedWrite, LinesCodec};

#[derive(Debug)]
struct AccountChanged;
impl std::fmt::Display for AccountChanged {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Codex account changed")
    }
}
impl std::error::Error for AccountChanged {}

fn error_code(error: &anyhow::Error) -> &'static str {
    if error.is::<AccountChanged>() {
        "codex_auth_account_changed"
    } else {
        "codex_auth_unavailable"
    }
}

const LIMIT: usize = 64 * 1024;
const DEADLINE: Duration = Duration::from_secs(8);

/// No terminal can accidentally display the bearer token. The app launches
/// this with private pipes and owns consent, request correlation and delivery.
pub async fn run(home: PathBuf, codex: PathBuf) -> Result<()> {
    ignore_broken_pipe()?;
    ensure!(
        !std::io::stdin().is_terminal() && !std::io::stdout().is_terminal(),
        "Codex auth broker requires private input and output pipes"
    );
    ensure!(home.is_absolute() && codex.is_absolute(), "broker paths must be absolute");
    let checked_home = home.clone();
    let lock = tokio::task::spawn_blocking(move || prepare(&checked_home)).await??;
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let Some(mut owner) = Owner::start(&home, &codex, &lock, &mut terminate).await? else {
        // SIGTERM arrived while the managed Codex owner was initializing. The
        // startup path has already reaped that child before releasing `lock`.
        return Ok(());
    };
    let result = tokio::select! {
        result = serve(&mut owner, &home) => result,
        _ = terminate.recv() => Ok(()),
        _ = tokio::signal::ctrl_c() => Ok(()),
    };
    owner.stop().await;
    result
}

fn ignore_broken_pipe() -> Result<()> {
    // The CLI defaults SIGPIPE for ordinary pipelines. This private owner must
    // instead receive EPIPE and stop/reap Codex before releasing its lock.
    // SAFETY: SIG_IGN is a supported process-wide disposition for SIGPIPE.
    ensure!(
        unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) } != libc::SIG_ERR,
        "cannot configure broker pipe handling"
    );
    Ok(())
}

async fn serve(owner: &mut Owner, home: &Path) -> Result<()> {
    // Tokio stdin uses an uncancellable blocking read. A private nonblocking
    // descriptor lets cancellation finish even if the app keeps its pipe open.
    let input = private_pipe(libc::STDIN_FILENO)?;
    let mut buffered = Vec::new();
    let output = private_pipe(libc::STDOUT_FILENO)?;
    while let Some(line) = request_line(&input, &mut buffered).await? {
        let request: Value =
            serde_json::from_str(&line).map_err(|_| anyhow!("invalid broker request"))?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("broker request needs a numeric id"))?;
        let reply = match tokio::time::timeout(DEADLINE, owner.request(home, &request)).await {
            Ok(Ok(result)) => json!({"id": id, "result": result}),
            Ok(Err(error)) => json!({"id": id, "error": error_code(&error)}),
            Err(_) => {
                // A timed-out app-server request may still mutate the cache.
                // End this owned child before releasing the exclusive lock.
                owner.stop().await;
                tokio::time::timeout(
                    DEADLINE,
                    write_reply(&output, &json!({"id": id, "error": "codex_auth_timeout"})),
                )
                .await
                .ok();
                return Err(anyhow!("Codex auth broker timed out"));
            }
        };
        tokio::time::timeout(DEADLINE, write_reply(&output, &reply))
            .await
            .map_err(|_| anyhow!("broker output timed out"))??;
    }
    Ok(())
}

fn private_pipe(source: i32) -> Result<tokio::io::unix::AsyncFd<OwnedFd>> {
    // SAFETY: duplicate a stdio descriptor; OwnedFd owns only the new descriptor.
    let fd = unsafe { libc::fcntl(source, libc::F_DUPFD_CLOEXEC, 3) };
    ensure!(fd >= 0, "cannot open broker pipe");
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    nonblocking_input(fd)
}

async fn write_reply(output: &tokio::io::unix::AsyncFd<OwnedFd>, reply: &Value) -> Result<()> {
    let mut bytes = zeroize::Zeroizing::new(reply.to_string().into_bytes());
    bytes.push(b'\n');
    ensure!(bytes.len() <= LIMIT, "broker reply too large");
    let mut offset = 0;
    while offset < bytes.len() {
        let mut ready = output.writable().await?;
        match ready.try_io(|source| {
            // SAFETY: bytes stays alive and offset never exceeds its length.
            let n = unsafe {
                libc::write(
                    source.get_ref().as_raw_fd(),
                    bytes.get(offset..).unwrap_or_default().as_ptr().cast(),
                    bytes.len() - offset,
                )
            };
            if n < 0 { Err(std::io::Error::last_os_error()) } else { Ok(n as usize) }
        }) {
            Ok(Ok(0)) | Ok(Err(_)) => return Err(anyhow!("broker output closed")),
            Ok(Ok(n)) => offset += n,
            Err(_) => continue,
        }
    }
    Ok(())
}

fn nonblocking_input(fd: OwnedFd) -> Result<tokio::io::unix::AsyncFd<OwnedFd>> {
    // SAFETY: fd is owned and live; fcntl changes only this private pipe.
    let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
    ensure!(
        flags >= 0
            && unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
        "cannot make broker input nonblocking"
    );
    Ok(tokio::io::unix::AsyncFd::new(fd)?)
}

async fn request_line(
    input: &tokio::io::unix::AsyncFd<OwnedFd>,
    buffered: &mut Vec<u8>,
) -> Result<Option<String>> {
    loop {
        if let Some(end) = buffered.iter().position(|b| *b == b'\n') {
            let line = buffered.drain(..=end).collect::<Vec<_>>();
            return String::from_utf8(line)
                .map(Some)
                .map_err(|_| anyhow!("invalid broker request"));
        }
        ensure!(buffered.len() <= 4096, "broker request too large");
        let mut bytes = [0u8; 4097];
        let mut ready = input.readable().await?;
        match ready.try_io(|source| {
            // SAFETY: bytes is writable for the requested bound; fd stays owned.
            let n = unsafe {
                libc::read(
                    source.get_ref().as_raw_fd(),
                    bytes.as_mut_ptr().cast(),
                    4097 - buffered.len(),
                )
            };
            if n < 0 { Err(std::io::Error::last_os_error()) } else { Ok(n as usize) }
        }) {
            Ok(Ok(0)) => {
                ensure!(buffered.is_empty(), "incomplete broker request");
                return Ok(None);
            }
            Ok(Ok(n)) => buffered.extend_from_slice(bytes.get(..n).unwrap_or_default()),
            Ok(Err(_)) => return Err(anyhow!("broker input closed")),
            Err(_) => continue,
        }
    }
}

/// A marker prevents accidentally pointing this at an existing CLI home and
/// making two independent users of the same rotating refresh credential.
fn prepare(home: &Path) -> Result<File> {
    crate::config::private_state_dir(home)?;
    let lock = crate::config::private_state_rw(&home.join("broker.lock"))?;
    lock.try_lock().map_err(|_| anyhow!("another Codex auth broker owns this sign-in"))?;
    let marker = home.join("broker-owned");
    if !marker.exists() {
        ensure!(
            !home.join("auth.json").exists() && !home.join("config.toml").exists(),
            "broker needs a new dedicated Codex home; importing a shared sign-in is not allowed"
        );
        crate::config::private_state_rw(&marker)?;
    }
    ensure!(
        !home.join("config.toml").exists(),
        "broker home must not contain provider configuration"
    );
    Ok(lock)
}

struct Owner {
    child: Child,
    input: FramedWrite<ChildStdin, LinesCodec>,
    output: FramedRead<ChildStdout, LinesCodec>,
    lock: File,
    next_id: u64,
    account: Option<String>,
}

impl Drop for Owner {
    fn drop(&mut self) {
        if let Some(pid) = self.child.id() {
            // SAFETY: this unreaped child leads the group we created. Drop
            // cannot await Tokio's reaper, so kill the group without unlocking.
            // Its inherited descriptor keeps the lock until Codex really exits.
            unsafe {
                libc::killpg(pid as libc::pid_t, libc::SIGKILL);
            }
        }
    }
}

enum StartupCancellation<'a> {
    Signal(&'a mut tokio::signal::unix::Signal),
    #[cfg(test)]
    Channel(&'a mut tokio::sync::oneshot::Receiver<()>),
}

impl StartupCancellation<'_> {
    async fn wait(&mut self) {
        match self {
            Self::Signal(signal) => {
                let _ = signal.recv().await;
            }
            #[cfg(test)]
            Self::Channel(receiver) => {
                let _ = (&mut **receiver).await;
            }
        }
    }
}

impl Owner {
    async fn stop(&mut self) {
        if let Some(pid) = self.child.id() {
            // SAFETY: this unreaped child leads the process group we created.
            // End a CLI wrapper's children too, before releasing the auth lock.
            unsafe {
                libc::killpg(pid as libc::pid_t, libc::SIGKILL);
            }
            if self.child.wait().await.is_err() {
                // No confirmed exit: retain the inherited lock protection.
                return;
            }
        }
        // A child forked before exec can retain the inherited open file
        // description after its owner exits. Explicitly unlocking our clone
        // releases the flock without waiting for every inherited descriptor
        // to close. Only the reaped stop path may explicitly unlock.
        let _ = self.lock.unlock();
    }

    async fn start(
        home: &Path,
        codex: &Path,
        lock: &File,
        terminate: &mut tokio::signal::unix::Signal,
    ) -> Result<Option<Self>> {
        Self::start_with_cancel(home, codex, lock, StartupCancellation::Signal(terminate)).await
    }

    async fn start_with_cancel(
        home: &Path,
        codex: &Path,
        lock: &File,
        mut cancel: StartupCancellation<'_>,
    ) -> Result<Option<Self>> {
        let mut command = Command::new(codex);
        command.process_group(0);
        let owned_lock = lock.try_clone().map_err(|_| anyhow!("cannot retain broker lock"))?;
        let lock_fd = lock.as_raw_fd();
        // SAFETY: the lock lives through this child. fcntl is async-signal-safe.
        // The child retains the same locked open-file description if its parent
        // crashes, so a replacement cannot refresh while that child still lives.
        unsafe {
            command.pre_exec(move || {
                let flags = libc::fcntl(lock_fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(lock_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        // Never inherit API keys, custom endpoints or a different CODEX_HOME.
        command.env_clear();
        for key in ["HOME", "PATH", "USER", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            if let Some(value) = std::env::var_os(key) {
                command.env(key, value);
            }
        }
        let mut child = command
            .env("CODEX_HOME", home)
            .args(["-c", "cli_auth_credentials_store=\"file\"", "app-server"])
            .current_dir(home)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| anyhow!("cannot start the local Codex auth owner"))?;
        let stdin = child.stdin.take().ok_or_else(|| anyhow!("Codex input missing"))?;
        let stdout = child.stdout.take().ok_or_else(|| anyhow!("Codex output missing"))?;
        let mut owner = Self {
            child,
            input: FramedWrite::new(stdin, LinesCodec::new_with_max_length(LIMIT)),
            output: FramedRead::new(stdout, LinesCodec::new_with_max_length(LIMIT)),
            lock: owned_lock,
            next_id: 0,
            account: None,
        };
        let initialized = tokio::select! {
            result = tokio::time::timeout(
                DEADLINE,
                owner.call(
                    "initialize",
                    json!({
                        "clientInfo": {"name": "cmux-auth-owner", "version": env!("CARGO_PKG_VERSION")}
                    }),
                ),
            ) => result,
            _ = cancel.wait() => {
                owner.stop().await;
                return Ok(None);
            }
        };
        if !matches!(initialized, Ok(Ok(_))) {
            owner.stop().await;
            return Err(anyhow!("Codex initialization failed"));
        }
        let initialized_notification = tokio::select! {
            result = owner.input.send(json!({"method": "initialized"}).to_string()) => result,
            _ = cancel.wait() => {
                owner.stop().await;
                return Ok(None);
            }
        };
        if initialized_notification.is_err() {
            owner.stop().await;
            return Err(anyhow!("Codex initialization failed"));
        }
        Ok(Some(owner))
    }

    async fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        self.next_id += 1;
        let id = self.next_id;
        self.input.send(json!({"id": id, "method": method, "params": params}).to_string()).await?;
        while let Some(line) = self.output.next().await {
            let line = line.map_err(|_| anyhow!("Codex auth response invalid"))?;
            let reply: Value =
                serde_json::from_str(&line).map_err(|_| anyhow!("Codex auth response invalid"))?;
            if reply.get("method").is_none() && reply.get("id") == Some(&json!(id)) {
                ensure!(reply.get("error").is_none(), "Codex auth operation failed");
                return reply
                    .get("result")
                    .cloned()
                    .ok_or_else(|| anyhow!("Codex auth result missing"));
            }
            if reply.get("method").is_some() && reply.get("id").is_some() {
                // This managed owner never accepts delegated tools or external auth.
                self.input
                    .send(
                        json!({"id": reply["id"], "error": {
                            "code": -32601, "message": "Unsupported auth-owner request"
                        }})
                        .to_string(),
                    )
                    .await?;
            }
        }
        Err(anyhow!("Codex auth owner exited"))
    }

    async fn request(&mut self, home: &Path, request: &Value) -> Result<Value> {
        match request.get("method").and_then(Value::as_str) {
            Some("login") => {
                if self.account.is_some() {
                    return Err(AccountChanged.into());
                }
                // Access polling must not return a previous process's cache
                // before this explicitly requested browser sign-in finishes.
                self.call("account/logout", json!({})).await?;
                let response =
                    self.call("account/login/start", json!({"type": "chatgptDeviceCode"})).await?;
                let code = response
                    .get("userCode")
                    .and_then(Value::as_str)
                    .filter(|code| !code.is_empty() && code.len() < 64)
                    .ok_or_else(|| anyhow!("Codex did not return a device code"))?;
                ensure!(
                    response["verificationUrl"] == "https://auth.openai.com/codex/device",
                    "Codex returned an unexpected sign-in destination"
                );
                Ok(
                    json!({"verificationUrl": "https://auth.openai.com/codex/device", "userCode": code}),
                )
            }
            Some("access") => {
                // Serialized by this process and the lifetime lock. Codex persists
                // every rotation itself; no original seed ever overwrites it.
                self.call("account/read", json!({"refreshToken": request["force"] == true}))
                    .await?;
                let path = home.join("auth.json");
                let token = tokio::task::spawn_blocking(move || access(&path)).await??;
                let account = token["chatgptAccountId"]
                    .as_str()
                    .ok_or_else(|| anyhow!("Codex account missing"))?;
                if let Some(expected) = self.account.as_deref()
                    && account != expected
                {
                    return Err(AccountChanged.into());
                }
                if let Some(expected) = request.get("previousAccountId").and_then(Value::as_str)
                    && account != expected
                {
                    return Err(AccountChanged.into());
                }
                self.account = Some(account.to_owned());
                Ok(token)
            }
            Some("logout") => {
                self.call("account/logout", json!({})).await?;
                self.account = None;
                Ok(json!({"signedOut": true}))
            }
            _ => Err(anyhow!("unsupported broker operation")),
        }
    }
}

#[cfg(test)]
#[path = "codex_auth_broker_tests.rs"]
mod tests;

/// Read the cache Codex just wrote and return only the external-token shape.
/// No caller can request the refresh token, ID token or full cache.
fn access(path: &Path) -> Result<Value> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    // SAFETY: getuid has no preconditions.
    ensure!(
        metadata.is_file()
            && metadata.uid() == unsafe { libc::getuid() }
            && metadata.mode() & 0o077 == 0
            && metadata.len() <= LIMIT as u64,
        "Codex auth cache must be a private regular file"
    );
    let mut bytes = zeroize::Zeroizing::new(Vec::new());
    file.take(LIMIT as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= LIMIT, "Codex auth cache too large");
    let cache: Value =
        serde_json::from_slice(&bytes).map_err(|_| anyhow!("Codex auth cache invalid"))?;
    ensure!(cache["auth_mode"] == "chatgpt", "broker requires Codex-managed ChatGPT sign-in");
    let tokens = &cache["tokens"];
    let token = tokens["access_token"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("Codex access token missing"))?;
    let account = tokens["account_id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("Codex account missing"))?;
    let payload = token.split('.').nth(1).ok_or_else(|| anyhow!("Codex access token invalid"))?;
    let claims = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|_| anyhow!("Codex access token invalid"))?;
    let claims: Value =
        serde_json::from_slice(&claims).map_err(|_| anyhow!("Codex access token invalid"))?;
    let expiry = claims["exp"].as_u64().ok_or_else(|| anyhow!("Codex access expiry missing"))?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    ensure!(expiry > now + 60, "Codex access token has expired");
    Ok(json!({"accessToken": token, "chatgptAccountId": account, "expiresAt": expiry}))
}
