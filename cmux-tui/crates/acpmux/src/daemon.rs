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
}

pub async fn run(opts: DaemonOptions) -> Result<()> {
    import_login_env().await;
    let mut config = Config::load()?;
    crate::config::verify_launchers(&mut config);
    if opts.memory {
        config.store.mode = crate::config::StoreMode::Memory;
    }
    if config.harnesses.is_empty() {
        tracing::warn!("no harnesses configured; add {{\"harnesses\":{{\"codex\":{{\"argv\":[\"codex-acp\"]}}}}}} to {}", Config::path().display());
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
    let ws = opts
        .ws_listen
        .clone()
        .map(|listen| (listen, opts.ws_token.clone().or_else(|| config.websocket.as_ref().and_then(|w| w.token.clone()))))
        .or_else(|| config.websocket.clone().map(|w| (w.listen, w.token)));
    if let Some((listen, token)) = &ws {
        let mut cfg = config.clone();
        cfg.websocket = Some(crate::config::WebSocketConfig { listen: listen.clone(), token: token.clone() });
        config = cfg;
    }
    let hub = Hub::new(config, store);
    std::fs::write(home().join("daemon.pid"), std::process::id().to_string())?;
    hub.probe_models().await;
    tokio::spawn(notify_loop(hub.clone()));

    let unix = tokio::spawn(crate::server::listen_unix(hub.clone(), socket_path()));
    let ws_task = ws.map(|(listen, token)| tokio::spawn(crate::server::listen_ws(hub.clone(), listen, token)));

    let shutdown = async {
        let ctrl_c = tokio::signal::ctrl_c();
        #[cfg(unix)]
        {
            let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
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
    if let Some(t) = ws_task {
        t.abort();
    }
    hub.shutdown_all().await;
    let _ = std::fs::remove_file(socket_path());
    let _ = std::fs::remove_file(home().join("daemon.pid"));
    Ok(())
}

/// launchd starts the daemon with a bare environment: no `ANTHROPIC_*`,
/// no tool PATH, none of the exports in `.zshenv`/`.zprofile`. Agents then
/// behave differently from the same command in an ssh shell ("Not logged
/// in"). When started by launchd (`XPC_SERVICE_NAME` set) or with
/// `ACPMUX_LOGIN_ENV=1`, read the login shell's environment once and fill
/// in what is missing; the login PATH goes first. `ACPMUX_LOGIN_ENV=0`
/// turns this off.
async fn import_login_env() {
    match std::env::var("ACPMUX_LOGIN_ENV").as_deref() {
        Ok("0") => return,
        Ok("1") => {}
        _ if std::env::var_os("XPC_SERVICE_NAME").is_none() => return,
        _ => {}
    }
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let run = tokio::process::Command::new(&shell)
        .args(["-lic", "command env -0"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .env("ACPMUX_LOGIN_ENV", "0")
        .output();
    let out = match tokio::time::timeout(Duration::from_secs(15), run).await {
        Ok(Ok(o)) => o,
        Ok(Err(e)) => {
            tracing::warn!("login shell env: {shell}: {e}");
            return;
        }
        Err(_) => {
            tracing::warn!("login shell env: {shell} did not finish in 15s");
            return;
        }
    };
    let (vars, login_path) = parse_env0(&String::from_utf8_lossy(&out.stdout));
    let mut added = 0usize;
    for (key, value) in vars {
        if std::env::var_os(&key).is_none() {
            // SAFETY: single-threaded here; nothing else reads the environment yet.
            unsafe { std::env::set_var(&key, &value) };
            added += 1;
        }
    }
    if let Some(lp) = login_path {
        let current = std::env::var("PATH").unwrap_or_default();
        let mut merged: Vec<String> = lp.split(':').filter(|p| !p.is_empty()).map(str::to_owned).collect();
        for p in current.split(':') {
            if !p.is_empty() && !merged.iter().any(|m| m == p) {
                merged.push(p.to_owned());
            }
        }
        unsafe { std::env::set_var("PATH", merged.join(":")) };
    }
    tracing::info!(shell = %shell, added, "imported login shell environment");
}

/// Parse `env -0` output: (variables worth importing, the login PATH).
/// Shell-private and per-process variables are dropped; anything an rc
/// file printed before `env` ran is discarded up to the last newline.
fn parse_env0(text: &str) -> (Vec<(String, String)>, Option<String>) {
    let skip = ["PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_SESSION_ID", "TTY", "LOGNAME", "HOME", "USER", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "ACPMUX_LOGIN_ENV"];
    let mut vars = Vec::new();
    let mut login_path = None;
    for chunk in text.split('\0') {
        let Some(eq) = chunk.find('=') else { continue };
        let start = chunk[..eq].rfind('\n').map(|i| i + 1).unwrap_or(0);
        let key = &chunk[start..eq];
        let value = &chunk[eq + 1..];
        if key.is_empty() || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') || key.starts_with("XPC_") || skip.contains(&key) {
            continue;
        }
        if key == "PATH" {
            login_path = Some(value.to_owned());
        } else {
            vars.push((key.to_owned(), value.to_owned()));
        }
    }
    (vars, login_path)
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
            return Err(anyhow!("daemon did not come up at {}; see {}", path.display(), home().join("daemon.log").display()));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn spawn_detached() -> Result<()> {
    let exe = std::env::current_exe()?;
    std::fs::create_dir_all(home())?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(home().join("daemon.log"))?;
    let log_err = log.try_clone()?;
    let mut cmd = std::process::Command::new(exe);
    crate::config::scrub_nested_claude_env(&mut cmd);
    cmd.args(["daemon", "run"])
        .stdin(std::process::Stdio::null())
        .stdout(log)
        .stderr(log_err);
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
            "permission_request" => format!("{name} needs a permission: {}", ev.record.msg.pointer("/request/toolCall/title").and_then(Value::as_str).unwrap_or("tool")),
            _ => format!("{name} finished ({})", ev.record.msg.get("status").and_then(Value::as_str).unwrap_or("completed")),
        };
        let mut c = tokio::process::Command::new("sh");
        c.arg("-c").arg(&cmd).env("ACPMUX_EVENT", kind).env("ACPMUX_SESSION_ID", &ev.session_id).env("ACPMUX_SESSION_NAME", &name).env("ACPMUX_TEXT", &text);
        crate::config::scrub_nested_claude_env_tokio(&mut c);
        let _ = c.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_env0_and_drops_noise() {
        let text = "fnm: using node 22\nANTHROPIC_BASE_URL=http://x\0PATH=/a:/b\0PWD=/tmp\0XPC_SERVICE_NAME=svc\0BAD KEY=1\0MULTI=a\nb\0";
        let (vars, path) = parse_env0(text);
        assert_eq!(path.as_deref(), Some("/a:/b"));
        assert_eq!(vars, vec![("ANTHROPIC_BASE_URL".to_owned(), "http://x".to_owned()), ("MULTI".to_owned(), "a\nb".to_owned())]);
    }
}
