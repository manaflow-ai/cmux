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
}

/// How long SIGTERM or `_acpmux/shutdown` may take before the daemon exits
/// anyway.
pub const SHUTDOWN_BUDGET: Duration = Duration::from_secs(5);

pub async fn run(opts: DaemonOptions) -> Result<()> {
    let login_env = crate::login_env::requested();
    let mut config = Config::load()?;
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
    if config.websocket.is_none() {
        config.websocket = Some(crate::config::WebSocketConfig {
            listen: "127.0.0.1:47811".into(),
            token: Some(random_token()),
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
        config.websocket =
            Some(crate::config::WebSocketConfig { listen: addr.clone(), token: token.clone() });
    }
    let hub = Hub::new(config, store);
    hub.begin_startup(login_env);
    std::fs::write(home().join("daemon.pid"), std::process::id().to_string())?;
    let unix = tokio::spawn(crate::server::serve_unix(hub.clone(), unix_listener));
    let ws_task =
        ws_listener.map(|(l, token)| tokio::spawn(crate::server::serve_ws(hub.clone(), l, token)));
    let ready = serde_json::json!({
        "ready": true,
        "pid": std::process::id(),
        "socket": socket_path(),
        "listen": bound,
        "webUrl": hub.config.read().await.websocket.as_ref().map(crate::hub::web_url),
    });
    tracing::info!("acpmux ready {ready}");
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

/// Connect to the daemon, starting one if needed.
pub async fn connect(autostart: bool) -> Result<Arc<Client>> {
    let path = socket_path();
    if let Ok(c) = Client::connect(&path).await {
        return Ok(c);
    }
    if !autostart {
        return Err(anyhow!("no acpmux daemon at {} (run `acpmux daemon`)", path.display()));
    }
    spawn_detached()?;
    let deadline = std::time::Instant::now() + Duration::from_secs(8);
    loop {
        if let Ok(c) = Client::connect(&path).await {
            return Ok(c);
        }
        if std::time::Instant::now() > deadline {
            return Err(anyhow!(
                "daemon did not come up at {}; see {}",
                path.display(),
                home().join("daemon.log").display()
            ));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn spawn_detached() -> Result<()> {
    let exe = std::env::current_exe()?;
    std::fs::create_dir_all(home())?;
    let log =
        std::fs::OpenOptions::new().create(true).append(true).open(home().join("daemon.log"))?;
    let log_err = log.try_clone()?;
    let mut cmd = std::process::Command::new(exe);
    crate::config::scrub_nested_claude_env(&mut cmd);
    cmd.args(["daemon", "run"]).stdin(std::process::Stdio::null()).stdout(log).stderr(log_err);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // New session so the daemon outlives the terminal.
        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
    }
    cmd.spawn().context("spawn acpmux daemon")?;
    Ok(())
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
