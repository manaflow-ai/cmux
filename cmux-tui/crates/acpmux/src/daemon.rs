//! Daemon lifecycle: run the hub and listeners, or start a detached daemon
//! from a client command the way `tmux` starts its server on demand.

use crate::client::Client;
use crate::config::{Config, home, socket_path};
use crate::hub::Hub;
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

pub struct DaemonOptions {
    pub ws_listen: Option<String>,
    pub ws_token: Option<String>,
    pub memory: bool,
    /// Write one JSON readiness line to this file descriptor once the
    /// socket and the listen address are bound, then close it.
    pub ready_fd: Option<i32>,
    /// `--allow-dev-origin`: loopback page dev server origins, never saved.
    pub dev_origins: Vec<String>,
}

/// How long SIGTERM or `_acpmux/shutdown` may take before the daemon exits
/// anyway.
pub const SHUTDOWN_BUDGET: Duration = Duration::from_secs(5);

pub async fn run(opts: DaemonOptions) -> Result<()> {
    // The CLI restores default SIGPIPE so `acpmux ls | head` ends quietly. A
    // daemon must not die when its launcher or a client goes away mid-write:
    // a closed pipe is an ordinary write error here.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
    // Processes started before readiness (the login shell probe, agents)
    // must not hold the readiness pipe open.
    if let Some(fd) = opts.ready_fd.filter(|fd| *fd > 2) {
        unsafe {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
    }
    let login_env = crate::login_env::requested();
    let dev_origins = opts
        .dev_origins
        .iter()
        .map(|origin| crate::server::dev_origin(origin))
        .collect::<Result<Vec<_>>>()?;
    let mut config = Config::load()?;
    config.dev_origins = dev_origins;
    if opts.memory {
        config.store.mode = crate::config::StoreMode::Memory;
    }
    if config.harnesses.is_empty() && !login_env {
        tracing::warn!(
            "no harnesses configured; add {{\"harnesses\":{{\"codex\":{{\"argv\":[\"codex-acp\"]}}}}}} to {}",
            Config::path().display()
        );
    }
    std::fs::create_dir_all(home())?;
    // launchd starts us in /; sessions without a cwd default to home.
    if let Some(h) = dirs::home_dir() {
        let _ = std::env::set_current_dir(h);
    }
    let lock = home().join("daemon.lock");
    let _lock_file = acquire_lock(&lock)?;
    let store = crate::store::open(&config.store, &home())?;
    // The dashboard and WebSocket always run. First run picks a loopback port
    // and a random token and saves both, so the URL is stable afterwards.
    // The token is mandatory (plans/cmux-next/identity.md section 4): a saved
    // listener without one gets one, and the file keeps it.
    let needs_token = config
        .websocket
        .as_ref()
        .is_none_or(|w| w.token.as_deref().is_none_or(|t| t.trim().is_empty()));
    if needs_token {
        let listen = config.websocket.as_ref().map(|w| w.listen.clone());
        let (allowed_origins, allowed_hosts) = config
            .websocket
            .as_ref()
            .map(|w| (w.allowed_origins.clone(), w.allowed_hosts.clone()))
            .unwrap_or_default();
        config.websocket = Some(crate::config::WebSocketConfig {
            listen: listen.unwrap_or_else(|| "127.0.0.1:47811".into()),
            token: Some(random_token()),
            allowed_origins,
            allowed_hosts,
        });
        if let Err(e) = config.save() {
            tracing::warn!("could not save generated web config: {e}");
        }
    }
    let explicit_listen = opts.ws_listen.is_some();
    let ws = opts
        .ws_listen
        .clone()
        .map(|listen| {
            (
                listen,
                opts.ws_token
                    .clone()
                    .filter(|t| !t.trim().is_empty())
                    .or_else(|| config.websocket.as_ref().and_then(|w| w.token.clone())),
            )
        })
        .or_else(|| config.websocket.clone().map(|w| (w.listen, w.token)));

    // Bind before any slow startup work, so clients can connect and ask
    // `_acpmux/status` at once. Agent spawns wait for `finish_startup`.
    let unix_listener = crate::server::bind_unix(&socket_path()).await?;
    let ws_listener = match &ws {
        Some((listen, token)) => match crate::server::bind_ws(listen).await {
            Ok(l) => Some((l, token.clone())),
            Err(e) if !explicit_listen => {
                tracing::warn!("dashboard disabled: {e:#}");
                // Report no web listener; the saved address stays in the file.
                config.web_unbound = true;
                None
            }
            Err(e) => {
                let _ = std::fs::remove_file(socket_path());
                return Err(e);
            }
        },
        None => None,
    };
    // `--listen 127.0.0.1:0` asked for any free port; report the real one.
    let bound = ws_listener.as_ref().and_then(|(l, _)| l.local_addr().ok()).map(|a| a.to_string());
    if let (Some(addr), Some((_, token))) = (&bound, &ws) {
        let (allowed_origins, allowed_hosts) = config
            .websocket
            .as_ref()
            .map(|w| (w.allowed_origins.clone(), w.allowed_hosts.clone()))
            .unwrap_or_default();
        config.websocket = Some(crate::config::WebSocketConfig {
            listen: addr.clone(),
            token: token.clone(),
            allowed_origins,
            allowed_hosts,
        });
    }
    let hub = Hub::new(config, store);
    hub.begin_startup(login_env);
    std::fs::write(home().join("daemon.pid"), std::process::id().to_string())?;
    let unix = tokio::spawn(crate::server::serve_unix(hub.clone(), unix_listener));
    let ws_task = ws_listener.map(|(l, token)| {
        // `needs_token` above gave the saved listener a token.
        let token = token.unwrap_or_else(random_token);
        tokio::spawn(crate::server::serve_ws(hub.clone(), l, token))
    });
    let ready = serde_json::json!({
        "ready": true,
        "pid": std::process::id(),
        "socket": socket_path(),
        "listen": bound,
        "webUrl": hub.config.read().await.web_listener().map(crate::hub::web_url),
    });
    // The web URL carries the token; the log (often a 0644 file) never does.
    tracing::info!(
        "acpmux ready pid={} socket={} listen={}",
        std::process::id(),
        socket_path().display(),
        bound.as_deref().unwrap_or("none")
    );
    if let Some(fd) = opts.ready_fd {
        write_ready(fd, &ready);
    }
    {
        let hub = hub.clone();
        tokio::spawn(async move { hub.finish_startup().await });
    }
    tokio::spawn(notify_loop(hub.clone()));

    let shutdown = async {
        let ctrl_c = tokio::signal::ctrl_c();
        #[cfg(unix)]
        {
            let mut term =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
            tokio::select! {
                _ = ctrl_c => {},
                _ = async { match term.as_mut() { Some(t) => { t.recv().await; } None => std::future::pending::<()>().await } } => {},
                _ = hub.shutdown.notified() => {},
            }
        }
        #[cfg(not(unix))]
        {
            tokio::select! { _ = ctrl_c => {}, _ = hub.shutdown.notified() => {} }
        }
    };
    tokio::select! {
        r = unix => { r??; }
        _ = shutdown => {}
    }
    tracing::info!("shutting down");
    // New clients get "connection refused" instead of a dying daemon.
    let _ = std::fs::remove_file(socket_path());
    if let Some(t) = ws_task {
        t.abort();
    }
    if tokio::time::timeout(SHUTDOWN_BUDGET, hub.shutdown_all()).await.is_err() {
        tracing::warn!("agents did not stop within {SHUTDOWN_BUDGET:?}; exiting anyway");
        hub.flush();
    }
    let _ = std::fs::remove_file(home().join("daemon.pid"));
    tracing::info!("stopped");
    Ok(())
}

/// Write the readiness line to an inherited descriptor and close it.
fn write_ready(fd: i32, ready: &Value) {
    use std::io::Write;
    use std::os::fd::FromRawFd;
    if fd < 0 {
        return;
    }
    let mut line = ready.to_string();
    line.push('\n');
    // SAFETY: the launcher passed this descriptor for us to write and close.
    let mut f = unsafe { std::fs::File::from_raw_fd(fd) };
    if let Err(e) = f.write_all(line.as_bytes()) {
        tracing::warn!("--ready-fd {fd}: {e}");
    }
    if fd <= 2 {
        // Never close stdio.
        std::mem::forget(f);
    }
}

fn random_token() -> String {
    let mut bytes = [0u8; 24];
    let mut f = std::fs::File::open("/dev/urandom").expect("urandom");
    use std::io::Read;
    f.read_exact(&mut bytes).expect("urandom read");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn acquire_lock(path: &PathBuf) -> Result<std::fs::File> {
    use std::os::unix::io::AsRawFd;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        return Err(anyhow!("another acpmux daemon holds {}", path.display()));
    }
    Ok(file)
}

static DAEMON_PREFIX: std::sync::OnceLock<Vec<std::ffi::OsString>> = std::sync::OnceLock::new();

/// Arguments placed before `daemon run` when a client starts the daemon, for
/// a host binary that runs acpmux under a subcommand (`cmux acp daemon run`).
/// Set once, before the first `connect`.
pub fn set_daemon_prefix(prefix: Vec<std::ffi::OsString>) {
    let _ = DAEMON_PREFIX.set(prefix);
}

/// How long a started daemon may take to report that its socket is bound.
const START_BUDGET: Duration = Duration::from_secs(8);

/// Wait until no daemon holds this home's lock (the running one exited),
/// at most `SHUTDOWN_BUDGET` plus a margin. True when it was released.
pub async fn wait_for_exit() -> bool {
    wait_for_lock_release(home().join("daemon.lock"), SHUTDOWN_BUDGET + Duration::from_secs(2))
        .await
}

/// Polls a non-blocking `flock`, so the deadline always ends the wait: a
/// blocking `flock` on a worker thread would outlive the timeout and hold
/// up runtime teardown.
async fn wait_for_lock_release(lock: PathBuf, budget: Duration) -> bool {
    use std::os::unix::io::AsRawFd;
    let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).open(&lock) else {
        return true;
    };
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return true;
        }
        let kind = std::io::Error::last_os_error().kind();
        if kind != std::io::ErrorKind::WouldBlock && kind != std::io::ErrorKind::Interrupted {
            return false;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Connect to the daemon, starting one if needed.
pub async fn connect(autostart: bool) -> Result<Arc<Client>> {
    let path = socket_path();
    if let Ok(c) = Client::connect(&path).await {
        return Ok(c);
    }
    if !autostart {
        return Err(anyhow!("no acpmux daemon at {} (run `acpmux daemon`)", path.display()));
    }
    let ready = start_daemon().await?;
    Client::connect(&path).await.map_err(|e| not_ready(&path, &ready, &e))
}

/// A connected socket to the daemon, starting one if needed, for a client
/// that speaks the wire protocol itself (`acpmux stdio`).
pub async fn connect_stream() -> Result<tokio::net::UnixStream> {
    let path = socket_path();
    if let Ok(stream) = tokio::net::UnixStream::connect(&path).await {
        return Ok(stream);
    }
    let ready = start_daemon().await?;
    tokio::net::UnixStream::connect(&path).await.map_err(|e| not_ready(&path, &ready, &e.into()))
}

/// Start a daemon and wait until it reports readiness or exits. Returns its
/// readiness line (empty when it exited first).
async fn start_daemon() -> Result<String> {
    let path = socket_path();
    // Async pipe I/O, so the timeout cancels the read; a blocking read on a
    // worker thread would keep runtime teardown waiting on a hung daemon.
    let ready = tokio::net::unix::pipe::Receiver::from_file(spawn_detached()?)
        .context("wait for acpmux daemon")?;
    // The daemon writes one line to the pipe once its socket is bound, or
    // the pipe reaches end of file when it exits first (another daemon won
    // the lock, bad config). Either way the caller connects once afterwards.
    let wait = async move {
        use tokio::io::AsyncBufReadExt;
        let mut line = String::new();
        tokio::io::BufReader::new(ready).read_line(&mut line).await.map(|_| line)
    };
    match tokio::time::timeout(START_BUDGET, wait).await {
        Ok(read) => Ok(read.unwrap_or_default()),
        Err(_) => Err(anyhow!(
            "daemon did not come up at {} within {START_BUDGET:?}; see {}",
            path.display(),
            home().join("daemon.log").display()
        )),
    }
}

fn not_ready(path: &std::path::Path, ready: &str, error: &anyhow::Error) -> anyhow::Error {
    let why = if ready.trim().is_empty() {
        "exited before it was ready"
    } else {
        "is ready but refused the connection"
    };
    anyhow!(
        "daemon {why} at {}: {error:#}; see {}",
        path.display(),
        home().join("daemon.log").display()
    )
}

/// Open the daemon log for append, owner-only like the config file: the log
/// can carry agent output and request details. A log left by an older build
/// with wider bits is narrowed to 0600.
fn open_daemon_log(path: &std::path::Path) -> Result<std::fs::File> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;
    if log.metadata()?.permissions().mode() & 0o077 != 0 {
        log.set_permissions(std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("chmod 0600 {}", path.display()))?;
    }
    Ok(log)
}

/// Start `<exe> [prefix] daemon run --ready-fd N` in its own session and
/// return the read end of its readiness pipe.
fn spawn_detached() -> Result<std::fs::File> {
    use std::os::fd::FromRawFd;
    let exe = std::env::current_exe()?;
    std::fs::create_dir_all(home())?;
    let log = open_daemon_log(&home().join("daemon.log"))?;
    let log_err = log.try_clone()?;
    let mut fds = [0i32; 2];
    // SAFETY: fds has room for the two descriptors pipe writes.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error()).context("pipe for acpmux daemon readiness");
    }
    let (read_fd, write_fd) = (fds[0], fds[1]);
    // SAFETY: both descriptors were just created and are owned here.
    let (reader, writer) =
        unsafe { (std::fs::File::from_raw_fd(read_fd), std::fs::File::from_raw_fd(write_fd)) };
    // Neither end leaks into other children; pre_exec reopens the write end
    // for the daemon only.
    unsafe {
        libc::fcntl(read_fd, libc::F_SETFD, libc::FD_CLOEXEC);
        libc::fcntl(write_fd, libc::F_SETFD, libc::FD_CLOEXEC);
    }
    let mut cmd = std::process::Command::new(exe);
    crate::config::scrub_nested_claude_env(&mut cmd);
    // The daemon must use this client's state directory, including a host
    // override that its own environment would not reproduce.
    cmd.env("ACPMUX_HOME", home())
        .args(DAEMON_PREFIX.get().map(Vec::as_slice).unwrap_or_default())
        .args(["daemon", "run", "--ready-fd"])
        .arg(write_fd.to_string())
        .stdin(std::process::Stdio::null())
        .stdout(log)
        .stderr(log_err);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            cmd.pre_exec(move || {
                // New session so the daemon outlives the terminal; keep the
                // readiness descriptor open across exec.
                libc::setsid();
                libc::fcntl(write_fd, libc::F_SETFD, 0);
                Ok(())
            });
        }
    }
    cmd.spawn().context("spawn acpmux daemon")?;
    // Close this process's copy so end of file means the daemon closed it.
    drop(writer);
    Ok(reader)
}

/// Run `notify_command` from the config on two transitions only: a
/// permission request, and a turn that ended while no client was attached.
async fn notify_loop(hub: Arc<Hub>) {
    let mut rx = hub.subscribe();
    loop {
        let ev = match rx.recv().await {
            Ok(e) => e,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(_) => break,
        };
        let kind = ev.record.kind.as_str();
        if kind != "permission_request" && kind != "turn_result" {
            continue;
        }
        let Some(cmd) = hub.config.read().await.notify_command.clone() else { continue };
        let Ok(session) = hub.resolve(&ev.session_id) else { continue };
        let summary = hub.session_summary(&session);
        let attached = summary.get("attached").and_then(Value::as_u64).unwrap_or(0);
        if kind == "turn_result" && attached > 0 {
            continue;
        }
        let name = summary.get("name").and_then(Value::as_str).unwrap_or("").to_owned();
        let text = match kind {
            "permission_request" => format!(
                "{name} needs a permission: {}",
                ev.record
                    .msg
                    .pointer("/request/toolCall/title")
                    .and_then(Value::as_str)
                    .unwrap_or("tool")
            ),
            _ => format!(
                "{name} finished ({})",
                ev.record.msg.get("status").and_then(Value::as_str).unwrap_or("completed")
            ),
        };
        let mut c = tokio::process::Command::new("sh");
        crate::login_env::apply_tokio(&mut c);
        c.arg("-c")
            .arg(&cmd)
            .env("ACPMUX_EVENT", kind)
            .env("ACPMUX_SESSION_ID", &ev.session_id)
            .env("ACPMUX_SESSION_NAME", &name)
            .env("ACPMUX_TEXT", &text);
        crate::config::scrub_nested_claude_env_tokio(&mut c);
        let _ = c
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn daemon_log_is_owner_only_when_created_and_when_an_old_log_is_wider() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("acpmux-log-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;

        let fresh = dir.join("daemon.log");
        drop(open_daemon_log(&fresh).unwrap());
        assert_eq!(mode(&fresh), 0o600);

        let old = dir.join("old.log");
        std::fs::write(&old, b"kept\n").unwrap();
        std::fs::set_permissions(&old, std::fs::Permissions::from_mode(0o644)).unwrap();
        {
            use std::io::Write;
            let mut f = open_daemon_log(&old).unwrap();
            f.write_all(b"appended\n").unwrap();
        }
        assert_eq!(mode(&old), 0o600);
        assert_eq!(std::fs::read_to_string(&old).unwrap(), "kept\nappended\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn lock_release_wakes_the_waiter_and_a_held_lock_times_out() {
        let dir = std::env::temp_dir().join(format!("acpmux-lock-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let lock = dir.join("daemon.lock");
        let held = acquire_lock(&lock).unwrap();
        // Held for the whole budget: not released.
        assert!(!wait_for_lock_release(lock.clone(), Duration::from_millis(200)).await);
        let started = std::time::Instant::now();
        let waiter = tokio::spawn(wait_for_lock_release(lock.clone(), Duration::from_secs(10)));
        tokio::time::sleep(Duration::from_millis(100)).await;
        drop(held);
        assert!(waiter.await.unwrap());
        assert!(started.elapsed() < Duration::from_secs(5));
        // No lock file at all means no daemon.
        assert!(wait_for_lock_release(dir.join("absent.lock"), Duration::from_secs(1)).await);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
