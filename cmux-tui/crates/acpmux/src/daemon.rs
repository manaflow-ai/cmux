//! Daemon lifecycle: run the hub and listeners, or start a detached daemon
//! from a client command the way `tmux` starts its server on demand.

use crate::client::Client;
use crate::config::{Config, home, socket_path};
use crate::hub::Hub;
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;

pub(crate) mod exe_path;
mod lock;
#[cfg(unix)]
mod open_file_limit;
use lock::{LockHeld, acquire_lock, wait_for_lock_release};
mod router_owner;
#[cfg(unix)]
pub(crate) use router_owner::open_router_owner;
pub(crate) use router_owner::router_owner_path;
use router_owner::{ensure_router, release_router};
// Decided on every platform so its tests run everywhere; used on macOS only.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) mod login_placement;
#[cfg(target_os = "macos")]
pub(crate) mod login_session;
mod notify;
mod persist_retry;
#[cfg(windows)]
mod windows;

pub struct DaemonOptions {
    pub ws_listen: Option<String>,
    pub ws_token: Option<String>,
    pub memory: bool,
    /// Write one JSON readiness line to this file descriptor once the
    /// socket and the listen address are bound, then close it.
    pub ready_fd: Option<i32>,
    /// `--person-key-fd`: this launch's person key from the app that
    /// spawned the daemon (`hub/person.rs`); read and closed at once.
    pub person_key_fd: Option<i32>,
    /// `--allow-dev-origin`: loopback page dev server origins, never saved.
    pub dev_origins: Vec<String>,
    /// `--dev`: a development launch (see `dev_origins_permitted`).
    pub dev: bool,
}

/// The daemon's panic log, `$ACPMUX_HOME/panics.jsonl` (cmux-panic-log):
/// a panic in a request task ends only that task and used to leave just
/// two lines in `daemon.log` (the 2026-10-14 sort panic). The cmux-next
/// app sends new lines to Sentry.
pub fn panic_log_path() -> std::path::PathBuf {
    home().join("panics.jsonl")
}

/// Debug builds only: `thread` makes a worker thread panic once the hook
/// is installed (tests/panic_log.rs). Its line carries `"test": true`.
#[cfg(debug_assertions)]
const TEST_PANIC_ENV: &str = "ACPMUX_TEST_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "acpmux-panic-test";

/// Install the panic log hook; the previous hook (stderr, so `daemon.log`) still runs.
fn install_panic_log() {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "acpmux".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    let path = panic_log_path();
    cmux_panic_log::install_with_opener(
        move || {
            crate::config::private_state_append(&path)
                .map_err(|error| std::io::Error::other(error.to_string()))
        },
        fields,
        is_test_panic_thread,
    );
    #[cfg(debug_assertions)]
    #[allow(
        clippy::panic,
        reason = "debug-build test trigger for the acpmux panic log; release builds have no seam"
    )]
    if std::env::var(TEST_PANIC_ENV).as_deref() == Ok("thread") {
        let _ = std::thread::Builder::new()
            .name(TEST_PANIC_THREAD.into())
            // crash-allow: debug-only test trigger for the acpmux panic log
            .spawn(|| panic!("acpmux test panic"));
    }
}

/// The debug test trigger's thread; its line carries `"test": true`.
fn is_test_panic_thread(thread: &str) -> bool {
    #[cfg(debug_assertions)]
    {
        thread == TEST_PANIC_THREAD
    }
    #[cfg(not(debug_assertions))]
    {
        let _ = thread;
        false
    }
}

/// How long SIGTERM or `_acpmux/shutdown` may take before the daemon exits
/// anyway.
pub const SHUTDOWN_BUDGET: Duration = Duration::from_secs(5);

pub async fn run(opts: DaemonOptions) -> Result<()> {
    // The CLI restores default SIGPIPE so `acpmux ls | head` ends quietly. A
    // daemon must not die when its launcher or a client goes away mid-write:
    // a closed pipe is an ordinary write error here.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
    // Processes started before readiness (the login shell probe, agents)
    // must not hold the readiness pipe open.
    #[cfg(unix)]
    if let Some(fd) = opts.ready_fd.filter(|fd| *fd > 2) {
        unsafe {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
    }
    #[cfg(windows)]
    windows::keep_from_children(opts.ready_fd);
    // Before anything is spawned: the key never reaches a child.
    let person_key = opts.person_key_fd.and_then(read_person_key);
    let login_env = crate::login_env::requested();
    anyhow::ensure!(
        opts.dev_origins.is_empty() || dev_origins_permitted(cfg!(debug_assertions), opts.dev),
        "--allow-dev-origin is for development only: it needs a debug build or --dev"
    );
    let dev_origins = opts
        .dev_origins
        .iter()
        .map(|origin| crate::server::dev_origin(origin))
        .collect::<Result<Vec<_>>>()?;
    // State holds tokens, prompts and tool output. Older builds created the
    // home with the process umask; narrow it before reading any of them.
    crate::config::private_state_dir(&home())?;
    install_panic_log();
    // Before the store, the sockets and any agent: launchd's soft limit is 256.
    #[cfg(unix)]
    open_file_limit::raise();
    let mut config = Config::load()?;
    // config.json holds the dashboard token: owner-only, also when another
    // tool wrote it with the umask's mode and the daemon never saves it.
    narrow_to_owner(&Config::path());
    config.dev_origins = dev_origins;
    crate::login_env::set_extra_allow(config.login_env_allow.clone());
    if opts.memory {
        config.store.mode = crate::config::StoreMode::Memory;
    }
    if config.harnesses.is_empty() && !login_env {
        tracing::warn!(
            "no harnesses configured; add {{\"harnesses\":{{\"codex\":{{\"argv\":[\"codex-acp\"]}}}}}} to {}",
            Config::path().display()
        );
    }
    // launchd starts us in /. The daemon's own folder is its cwd, never the
    // home folder: nothing the daemon or a child does relative to its cwd may
    // walk the user's folders (LAUNCH-NO-TCC-PROMPTS).
    let _ = std::env::set_current_dir(home());
    exe_path::check_run(opts.ready_fd)?;
    let lock = home().join("daemon.lock");
    let _lock_file = match acquire_lock(&lock) {
        Ok(lock) => lock,
        Err(e) => {
            // The command that started this daemon waits for the holder (`connect`).
            if let Some(fd) = opts.ready_fd.filter(|_| e.downcast_ref::<LockHeld>().is_some()) {
                write_ready(fd, &serde_json::json!({"ready": false, "lockHeld": true}));
            }
            return Err(e);
        }
    };
    // The local CodeRouter relay (crate cmux-coderouter): `cmux-router` and
    // `local-coderouter` routes read its port and mint keys from it. Opt-in
    // (the cmux app sets ACPMUX_LOCAL_ROUTER=1). Its owner ties the router's
    // life to this daemon (daemon/router_owner.rs: the owner FIFO, shared
    // with the agent hosts, on Unix; a kill-on-close job on Windows).
    if std::env::var("ACPMUX_LOCAL_ROUTER").as_deref() == Ok("1") {
        ensure_router();
    }
    let store = crate::store::open(&config.store, &home())?;
    // The dashboard and WebSocket always run. First run picks a loopback port
    // and a random token and saves both, so the URL is stable afterwards.
    // The token is mandatory (plans/cmux-next/identity.md section 4): a saved
    // listener without one gets one, and the file keeps it.
    rotate_saved_token_once(&mut config);
    let needs_token = config
        .websocket
        .as_ref()
        .is_none_or(|w| w.token.as_deref().is_none_or(|t| t.trim().is_empty()));
    // Only the shared home owns the fixed port; any other home never saves it.
    let shared_home = dirs::home_dir().map(|h| h.join(".acpmux")) == Some(home());
    let saved_listen = config.websocket.as_ref().map(|w| w.listen.clone());
    let listen_ok =
        saved_listen.as_deref() == Some(first_run_listen(shared_home, saved_listen.as_deref()));
    if needs_token || !listen_ok {
        let kept_token = config
            .websocket
            .as_ref()
            .and_then(|w| w.token.clone())
            .filter(|t| !t.trim().is_empty());
        let (allowed_origins, allowed_hosts) = config
            .websocket
            .as_ref()
            .map(|w| (w.allowed_origins.clone(), w.allowed_hosts.clone()))
            .unwrap_or_default();
        config.websocket = Some(crate::config::WebSocketConfig {
            listen: first_run_listen(shared_home, saved_listen.as_deref()).to_owned(),
            token: Some(kept_token.map_or_else(random_token, Ok)?),
            allowed_origins,
            allowed_hosts,
            // A kept token was rotated just above; a new one is new.
            token_rotated: TOKEN_ROTATION,
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
    let mut moved_listener = false;
    let ws_listener = match &ws {
        // cx-fcaq: a taken explicit `--listen` stops the daemon (the caller
        // asked for that address). A taken configured port (an unrelated
        // program, or a squatter) moves the daemon to a free loopback port,
        // which it reports and saves; the app reads the port from status
        // and checks its listener before it connects, and a proof names its
        // transport, so a squatter on the old port relays nothing.
        Some((listen, token)) => match crate::server::bind_ws(listen).await {
            Ok(l) => Some((l, token.clone())),
            Err(e) if explicit_listen => {
                let _ = std::fs::remove_file(socket_path());
                return Err(e.context(format!(
                    "the WebSocket listener {listen} (--listen) is taken; free the port or choose another"
                )));
            }
            Err(e) => {
                tracing::warn!(
                    "websocket.listen {listen} is taken ({e:#}); listening on a free loopback port"
                );
                match crate::server::bind_ws("127.0.0.1:0").await {
                    Ok(l) => {
                        moved_listener = true;
                        Some((l, token.clone()))
                    }
                    Err(e) => {
                        let _ = std::fs::remove_file(socket_path());
                        return Err(e.context("no free loopback port for the WebSocket listener"));
                    }
                }
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
        let token_rotated = config.websocket.as_ref().map_or(0, |w| w.token_rotated);
        // A later save (policy, peers, presets) writes the saved token, never
        // a `--token` value for this run.
        let saved_token = config.websocket.as_ref().and_then(|w| w.token.clone());
        if token != &saved_token {
            config.web_token_override = token.clone();
        }
        config.websocket = Some(crate::config::WebSocketConfig {
            listen: addr.clone(),
            token: saved_token.or_else(|| token.clone()),
            allowed_origins,
            allowed_hosts,
            token_rotated,
        });
        // The new port is this home's port from now on.
        if moved_listener && let Err(e) = config.save() {
            tracing::warn!("could not save the moved web listener: {e}");
        }
    }
    let mailbox = crate::mailbox::Mailbox::open(home().join("mailbox"))?;
    let memory_store = config.store.mode == crate::config::StoreMode::Memory;
    // Only the session list before the ready line; the chat logs load right after it.
    let hub = Hub::new_deferred(config, store, mailbox);
    // Temporary folders of sessions this daemon no longer has, before the
    // socket serves (`agent/session_tmp.rs`).
    #[cfg(unix)]
    hub.sweep_session_tmp();
    // The forum log (`forum.rs`): on disk unless the store is in memory; a
    // log that cannot open leaves the posts in memory.
    if !memory_store && let Err(e) = hub.open_forum(&home().join("forum")) {
        tracing::warn!("forum log unavailable, keeping posts in memory: {e:#}");
    }
    // Messages `send --no-wait` handed over (`hub/outbox.rs`): saved beside the sessions, and
    // what a restart left undelivered goes on.
    if !memory_store {
        let pending = hub.outbox.open(&home().join("outbox.json"));
        crate::server::outbox::resume(&hub, pending);
        hub.watches.open(&home().join("watches.json"));
    }
    crate::hub::watches::Watches::start(&hub);
    // The Macs whose app may allow here over the peer link (`hub/mac_approvers.rs`).
    hub.person.macs.open(home().join(crate::hub::mac_approvers::FILE));
    if let Some(key) = person_key {
        // A Team-signed daemon takes the key only from the signed app's
        // `_acpmux/person_enroll`: a same-uid process could restart it with
        // a key of its own.
        if cmux_link::app_caller::signed_app_build() {
            tracing::warn!(
                "--person-key-fd ignored: a signed daemon enrolls the app by its signature"
            );
        } else if let Err(e) = hub.person.install_spawn_key(&key) {
            tracing::warn!("--person-key-fd: {e}");
        }
    }
    // The curated model catalog (`catalog/`): the last good copy now, then a fetch at
    // once and every 6 h. `ACPMUX_CATALOG_FETCH=0` keeps the stored or bundled copy.
    let fetch_catalog = !std::env::var("ACPMUX_CATALOG_FETCH").is_ok_and(|v| v == "0");
    let fetcher: Option<std::sync::Arc<dyn crate::catalog::Fetcher>> =
        fetch_catalog.then(|| std::sync::Arc::new(crate::catalog::HttpsFetcher::current()) as _);
    hub.catalog.attach(home().join("catalog"), fetcher);
    if fetch_catalog {
        tokio::spawn(hub.catalog.clone().run());
    }
    // The app's pane sends no prompt before the folder's trust answer (`server/trust_gate.rs`).
    // Without a home directory no file can answer, so every folder waits (fails closed).
    hub.set_trust_gate(Some(crate::trust::Paths::current().unwrap_or_else(|| {
        let none = std::path::PathBuf::from("/nonexistent/acpmux-no-home");
        crate::trust::Paths {
            claude_json: none.join(".claude.json"),
            codex_config: none.join("config.toml"),
            record: none.join("trust.json"),
            agent_home: None,
            cmux_worktrees: None,
        }
    })));
    // Agents outlive this daemon unless the user opts out for this release.
    // `ACPMUX_IDLE_CHILD_SECS`: how long an unused session harness lives
    // (default 300; 0 keeps every harness running).
    if let Some(secs) =
        std::env::var("ACPMUX_IDLE_CHILD_SECS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        hub.set_idle_child((secs > 0).then(|| std::time::Duration::from_secs(secs)));
    }
    // `ACPMUX_PROBE_HARNESSES=a,b`: the model probes start only these
    // harnesses (the Chief lists the ones it uses); unset, every harness.
    hub.set_probe_only(Hub::probe_only_from_env(
        std::env::var("ACPMUX_PROBE_HARNESSES").ok().as_deref(),
    ));
    // The agent message runaway guard (`hub/agent_pairs.rs`): `ACPMUX_AGENT_PAIR_GUARD=0` turns
    // it off; `ACPMUX_AGENT_PAIR_{ALTERNATIONS,REPEATS,SIMILARITY,MAX_MESSAGES,WINDOW_SECS}` tune it.
    hub.set_agent_pair_guard(crate::hub::PairGuard::from_env(|k| std::env::var(k).ok()));
    if !std::env::var("ACPMUX_AGENT_HOSTS").is_ok_and(|v| v == "0") {
        hub.enable_agent_hosts();
    }
    hub.begin_startup(login_env);
    // Pairing tickets and paired machines, hashes only (`crate::pairing`).
    hub.pairing.persist_at(home().join("pairing.json"));
    // The ACP Registry and agent CLI health, off the startup path (`hub/health_view.rs`).
    hub.start_harness_checks();
    // Uploads past their age cap (`hub/file_uploads.rs`).
    hub.start_upload_sweep();
    // The pid file only explains a dropped connection (`client::closed_error`):
    // a daemon that cannot write it (a full disk) serves without it and tries
    // again, never exits (`daemon/persist_retry.rs`).
    let pid_retry = {
        let (path, pid) = (home().join("daemon.pid"), std::process::id().to_string());
        persist_retry::write_or_retry("daemon.pid", move || {
            crate::config::write_atomic(&path, pid.as_bytes())
        })
    };
    // The listener's token is on the hub before the unix socket serves, so a
    // `_acpmux/web_token_rotate` can never be overwritten by the launch token.
    let ws_listener = match ws_listener {
        Some((l, token)) => {
            // `needs_token` above gave the saved listener a token.
            let token = token.map_or_else(random_token, Ok)?;
            hub.web_token.set(token.clone());
            Some((l, token))
        }
        None => None,
    };
    let unix = tokio::spawn(crate::server::serve_unix(hub.clone(), unix_listener));
    // A new LocalApp token at every launch (`server/local_app.rs`), for the
    // app's bundled pane and an explicit `--allow-dev-origin` page only.
    let local_app = if ws_listener.is_some() {
        let mut pages = vec![crate::server::AGENT_PANE_ORIGIN.to_owned()];
        // The validated `--allow-dev-origin` values (loopback http, a port).
        pages.extend(hub.config.read().await.dev_origins.iter().cloned());
        match crate::server::local_app::LocalAppAuth::create(&home(), &pages) {
            Ok(auth) => Some(std::sync::Arc::new(auth)),
            Err(e) => {
                // Without it the pane is served as remote-origin, never wrongly local.
                tracing::warn!("no LocalApp token this run: {e:#}");
                None
            }
        }
    } else {
        None
    };
    // A new peer token at every launch (`server/peer_auth.rs`): the only
    // proof of a peer daemon, read by it over ssh, never over an RPC.
    let peer = if ws_listener.is_some() {
        match crate::server::peer_auth::PeerAuth::create(&home()) {
            Ok(auth) => Some(std::sync::Arc::new(auth)),
            Err(e) => {
                // Without it a peer is served as Web, never wrongly as Peer.
                tracing::warn!("no peer token this run: {e:#}");
                None
            }
        }
    } else {
        None
    };
    let local_app_file = local_app.as_ref().map(|a| a.path().to_owned());
    let peer_file = peer.as_ref().map(|a| a.path().to_owned());
    let ws_task = ws_listener.map(|(l, token)| {
        let auth = crate::server::WsAuth { local_app, peer };
        tokio::spawn(crate::server::serve_ws_with(hub.clone(), l, token, auth))
    });
    let ready = serde_json::json!({
        "ready": true,
        "pid": std::process::id(),
        "socket": socket_path(),
        "listen": bound,
        "webUrl": crate::hub::web_url(&*hub.config.read().await),
    });
    // The web URL carries the token; the log (often a 0644 file) never does.
    tracing::info!(
        "acpmux ready pid={} socket={} listen={}",
        std::process::id(),
        socket_path().display(),
        bound.as_deref().unwrap_or("none")
    );
    // The stop signals are registered before the ready line: a launcher may
    // stop the daemon as soon as it reads the line, and a signal that came
    // before registration would end the daemon by the default action
    // (no shutdown path: the token, pid file and socket would stay).
    #[cfg(unix)]
    let mut stop_signals = {
        use tokio::signal::unix::{SignalKind, signal};
        (signal(SignalKind::terminate()).ok(), signal(SignalKind::interrupt()).ok())
    };
    #[cfg(not(unix))]
    let ctrl_c = tokio::signal::ctrl_c();
    if let Some(fd) = opts.ready_fd {
        write_ready(fd, &ready);
    }
    // Debug builds only: `ACPMUX_TEST_HOLD_AFTER_READY_MS` holds the daemon
    // right after the ready line, so integration tests can stop it in that
    // window. Bounded; release builds have no seam.
    #[cfg(debug_assertions)]
    if let Some(ms) =
        std::env::var("ACPMUX_TEST_HOLD_AFTER_READY_MS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        tokio::time::sleep(Duration::from_millis(ms.min(5_000))).await;
    }
    #[cfg(all(unix, debug_assertions))]
    lock::fork_a_child_for_tests();
    // Profile files hot-reload (no polling); before startup work writes the config.
    hub.start_harness_watch();
    {
        let hub = hub.clone();
        tokio::spawn(async move {
            // Debug builds only: `ACPMUX_TEST_DELAY_LOAD_LOGS_MS` holds the chat-log
            // load and adoption, as a large log store did, so integration tests can ask in
            // that window. Bounded; release builds have no seam.
            #[cfg(debug_assertions)]
            if let Some(ms) = std::env::var("ACPMUX_TEST_DELAY_LOAD_LOGS_MS")
                .ok()
                .and_then(|v| v.parse::<u64>().ok())
            {
                tokio::time::sleep(Duration::from_millis(ms.min(10_000))).await;
            }
            // Agents that outlived the previous daemon come back first: their chats' logs
            // (tails, queues), then adoption. Every other chat's log is read in the background
            // after it, or first by a request for that chat (`hub/log_load.rs`).
            {
                let _adopted = crate::hub::AdoptionReady(&hub.adoption_ready);
                hub.load_live_logs_async().await;
                hub.adopt_agent_hosts().await;
                hub.settle_unadopted().await;
            }
            {
                let hub = hub.clone();
                tokio::spawn(async move {
                    hub.load_logs_async().await;
                    // Once every log is read: a pass reads only chats whose log is loaded.
                    let _worker = hub.retention_worker();
                });
            }
            // A chat a machine's Full-access setting moved out of its policy's mode goes back:
            // a revoke the previous daemon saved may not have reached it (`crate::pairing`).
            hub.hold_policies_again().await;
            hub.finish_startup().await;
            // After the login env import: it names harness homes.
            let sources = crate::chats::ChatSources::daemon(&*hub.config.read().await);
            if let Some(sources) = sources
                && let Err(e) = hub.start_chats(sources).await
            {
                tracing::warn!("{e}");
            }
        });
    }
    tokio::spawn(notify::notify_loop(hub.clone()));

    let shutdown = async {
        #[cfg(unix)]
        {
            let (term, int) = &mut stop_signals;
            tokio::select! {
                _ = next_signal(term.as_mut()) => {},
                _ = next_signal(int.as_mut()) => {},
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
    hub.stop_idle_reaper();
    // New clients get "connection refused" instead of a dying daemon.
    let _ = std::fs::remove_file(socket_path());
    if let Some(t) = ws_task {
        t.abort();
    }
    // How many hosted agents this shutdown kept running for the next
    // daemon; unknown (a timeout) counts as kept.
    let kept = match tokio::time::timeout(SHUTDOWN_BUDGET, hub.shutdown_all()).await {
        Ok(kept) => kept,
        Err(_) => {
            tracing::warn!("agents did not stop within {SHUTDOWN_BUDGET:?}; exiting anyway");
            hub.flush();
            usize::MAX
        }
    };
    // After the agents: their model streams go through the router.
    let _ = tokio::task::spawn_blocking(move || release_router(kept == 0)).await;
    // Cancelled and finished before the removal, so a late retry never puts it back.
    if let Some(retry) = pid_retry {
        retry.abort();
        let _ = retry.await;
    }
    let _ = std::fs::remove_file(home().join("daemon.pid"));
    for file in [local_app_file, peer_file].into_iter().flatten() {
        let _ = std::fs::remove_file(file);
    }
    tracing::info!("stopped");
    Ok(())
}

/// The next delivery of a registered signal; never, if registration failed.
#[cfg(unix)]
async fn next_signal(stream: Option<&mut tokio::signal::unix::Signal>) {
    match stream {
        Some(stream) => {
            stream.recv().await;
        }
        None => std::future::pending::<()>().await,
    }
}

/// Read the person key (one line, at most 128 bytes) from an inherited
/// descriptor and close it. The key is never logged.
#[cfg(unix)]
fn read_person_key(fd: i32) -> Option<String> {
    use std::io::Read;
    use std::os::fd::FromRawFd;
    if fd <= 2 {
        tracing::warn!("--person-key-fd {fd}: not a stdio descriptor");
        return None;
    }
    // Close the descriptor at exec too, so that no agent inherits it even
    // if a spawn starts before the read below returns.
    // SAFETY: fcntl on a descriptor number only sets its flags.
    unsafe {
        libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
    }
    if let Err(e) = not_dumpable() {
        // An agent this daemon starts (same uid) could read the key from
        // its memory: no key, so no allow, rather than a readable key.
        tracing::warn!(
            "--person-key-fd {fd}: refused, the daemon cannot be made not dumpable: {e}"
        );
        // SAFETY: the launcher passed this descriptor for us to close.
        drop(unsafe { std::fs::File::from_raw_fd(fd) });
        return None;
    }
    // SAFETY: the launcher passed this descriptor for us to read and close;
    // `File` owns and closes it here.
    let f = unsafe { std::fs::File::from_raw_fd(fd) };
    // A socket (`daemon start --person-key-fd`): say that this process is
    // not dumpable now; the launcher writes the key only after that, so a
    // same-uid reader of /proc/<pid>/fd before this point finds no key.
    if is_socket(&f) {
        use std::io::Write;
        if let Err(e) = (&f).write_all(KEY_READY) {
            tracing::warn!("--person-key-fd {fd}: {e}");
            return None;
        }
    }
    let mut buf = zeroize::Zeroizing::new(Vec::with_capacity(80));
    if let Err(e) = f.take(128).read_to_end(&mut buf) {
        tracing::warn!("--person-key-fd {fd}: {e}");
        return None;
    }
    let key = std::str::from_utf8(&buf).ok()?.trim().to_owned();
    if crate::hub::person::valid_key(&key) {
        Some(key)
    } else {
        tracing::warn!("--person-key-fd {fd}: not a person key");
        None
    }
}

/// What a daemon writes on a socket key descriptor once it is not dumpable.
const KEY_READY: &[u8] = b"nodump\n";

/// Whether `f` is a socket.
#[cfg(unix)]
fn is_socket(f: &std::fs::File) -> bool {
    use std::os::unix::fs::FileTypeExt;
    f.metadata().is_ok_and(|m| m.file_type().is_socket())
}

/// `acpmux daemon start --person-key-fd <fd>` (cx-0q7o slice 2a, D2): the
/// app's own ssh exec (or the VM provisioning exec) passes this launch's
/// person key on `fd` (stdin: 0). This process makes itself not dumpable,
/// reads one line, starts the daemon with a socket pair as its key
/// descriptor, and writes the key only after the daemon said it is not
/// dumpable. A daemon that already runs holds another key or none: this
/// refuses then (a keyed restart stops it first with `daemon shutdown
/// --keep-agents`). Returns the daemon's readiness line.
#[cfg(unix)]
pub async fn start_keyed(fd: i32) -> Result<String> {
    use std::io::Read;
    use std::os::fd::FromRawFd;
    not_dumpable().context("make the launcher not dumpable before it reads the person key")?;
    exe_path::check_start()?;
    let path = socket_path();
    if Client::connect(&path).await.is_ok() {
        return Err(anyhow!(
            "a daemon already runs at {}: it holds another person key or none; stop it with `acpmux daemon shutdown --keep-agents`, then start it again with the key",
            path.display()
        ));
    }
    // SAFETY: the caller passed this descriptor for this process to read;
    // ManuallyDrop: stdin stays open for the process.
    let input = std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(fd) });
    // Straight into one fixed buffer that is zeroed on drop: no reader
    // buffer keeps another copy. One line: 64 hex characters and a newline.
    let mut line = zeroize::Zeroizing::new([0u8; 129]);
    let mut filled = 0;
    while filled < line.len() && !line.get(..filled).unwrap_or_default().contains(&b'\n') {
        let Some(rest) = line.get_mut(filled..) else { break };
        match (&*input).read(rest) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e).context("read the person key"),
        }
    }
    let read = line.get(..filled).unwrap_or_default();
    let end = read.iter().position(|b| *b == b'\n').unwrap_or(filled);
    let key = zeroize::Zeroizing::new(
        std::str::from_utf8(read.get(..end).unwrap_or_default())
            .unwrap_or_default()
            .trim()
            .to_owned(),
    );
    if !crate::hub::person::valid_key(&key) {
        return Err(anyhow!(
            "--person-key-fd {fd}: not a person key (64 lowercase hex characters)"
        ));
    }
    // Another daemon is stopping or starting: start again until this key's daemon has the lock,
    // never leaving the caller to start an unkeyed one.
    let deadline = tokio::time::Instant::now() + HANDOVER_BUDGET;
    loop {
        let ready = start_daemon_with(Some(key.clone())).await?;
        if !lock_held(&ready) {
            // A keyed daemon that exited before it was ready fails this start: the caller must
            // not go on to start an unkeyed daemon in its place.
            anyhow::ensure!(
                !ready.trim().is_empty(),
                "the keyed daemon exited before it was ready; see {}",
                home().join("daemon.log").display()
            );
            return Ok(ready);
        }
        if tokio::time::Instant::now() + HANDOVER_RETRY >= deadline {
            return Err(anyhow!(
                "another acpmux daemon still holds {} after {HANDOVER_BUDGET:?}; the keyed daemon did not start",
                home().join("daemon.lock").display()
            ));
        }
        tokio::time::sleep(HANDOVER_RETRY).await;
        if Client::connect(&path).await.is_ok() {
            return Err(anyhow!(
                "a daemon started at {} meanwhile: it holds another person key or none; stop it with `acpmux daemon shutdown --keep-agents`, then start it again with the key",
                path.display()
            ));
        }
    }
}

/// Makes this process not dumpable before it holds a person key (cx-0q7o):
/// on Linux, a same-uid process (an agent the daemon starts) can then not
/// ptrace it or read its memory through /proc, and the kernel owns its
/// /proc files. Also logs yama's ptrace_scope, the host's other ptrace rule.
#[cfg(target_os = "linux")]
pub(crate) fn not_dumpable() -> std::io::Result<()> {
    // SAFETY: PR_SET_DUMPABLE takes an integer and changes only this
    // process's dumpable flag.
    if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: PR_GET_DUMPABLE reads this process's flag.
    if unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(std::io::Error::other("PR_GET_DUMPABLE is not 0 after PR_SET_DUMPABLE 0"));
    }
    match std::fs::read_to_string("/proc/sys/kernel/yama/ptrace_scope") {
        Ok(scope) => tracing::info!("person key: not dumpable; yama ptrace_scope {}", scope.trim()),
        Err(_) => tracing::info!("person key: not dumpable; yama is not active"),
    }
    Ok(())
}

/// macOS and other Unix: no dumpable flag. A DEV daemon is unsigned and
/// takes the key at spawn; a Release daemon is hardened-runtime signed,
/// which refuses a debugger without the get-task-allow entitlement, and
/// ignores the key descriptor (it enrolls the signed app instead).
#[cfg(all(unix, not(target_os = "linux")))]
pub(crate) fn not_dumpable() -> std::io::Result<()> {
    Ok(())
}

/// Windows: an inherited handle (`daemon/windows.rs`).
#[cfg(windows)]
fn read_person_key(fd: i32) -> Option<String> {
    windows::read_person_key(fd)
}

/// Write the readiness line to an inherited descriptor and close it.
#[cfg(unix)]
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
/// Windows: an inherited handle (`daemon/windows.rs`).
#[cfg(windows)]
fn write_ready(fd: i32, ready: &Value) {
    windows::write_ready(fd, ready)
}

/// Whether `--allow-dev-origin` may take effect: in a debug build, or with
/// an explicit `--dev` that release launchers never pass. A release config
/// refuses it, so a dev page origin never becomes a LocalApp origin there.
pub(crate) fn dev_origins_permitted(debug_build: bool, dev_flag: bool) -> bool {
    debug_build || dev_flag
}

/// Clears the group and other bits of `path`, if it exists.
#[cfg(unix)]
fn narrow_to_owner(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    let Ok(meta) = std::fs::metadata(path) else { return };
    let mode = meta.permissions().mode();
    if mode & 0o077 != 0
        && let Err(e) =
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode & 0o700))
    {
        tracing::warn!("could not make {} owner-only: {e}", path.display());
    }
}
/// Windows: replaces a wider access list with the owner-only one.
#[cfg(windows)]
use crate::owner_only::narrow as narrow_to_owner;

/// The rotation `websocket.tokenRotated` records (see `rotate_saved_token_once`).
const TOKEN_ROTATION: u32 = 1;

/// Builds before this one sent the saved WebSocket token to remote-origin
/// connections (`_acpmux/status` `webUrl`), so a token saved by one may be
/// known elsewhere: replace it once, at the first start of this build, and
/// mark it so it never rotates again. Every reader takes the token fresh
/// (the app's host and `acpmux web` from `_acpmux/status` over the unix
/// socket, ssh peers from the remote config at each connect); a `--token`
/// flag still overrides the listener's token. Returns whether it rotated.
fn rotate_saved_token_once(config: &mut crate::config::Config) -> bool {
    let Some(w) = config.websocket.as_mut() else { return false };
    if w.token_rotated >= TOKEN_ROTATION || w.token.as_deref().is_none_or(|t| t.trim().is_empty()) {
        return false;
    }
    let fresh = match random_token() {
        Ok(token) => token,
        Err(e) => {
            // Keep the saved token and try again at the next start.
            tracing::warn!("could not rotate the saved WebSocket token: {e}");
            return false;
        }
    };
    let old = w.token.replace(fresh);
    w.token_rotated = TOKEN_ROTATION;
    match config.save() {
        Ok(()) => {
            tracing::info!(
                "the saved WebSocket token was rotated once; run `acpmux web` for the new link"
            );
            true
        }
        Err(e) => {
            // Never run on a token the file does not hold (ssh peers read
            // the file): keep the old one and rotate at the next start.
            tracing::warn!("could not save the rotated WebSocket token; rotating next start: {e}");
            if let Some(w) = config.websocket.as_mut() {
                w.token = old;
                w.token_rotated = 0;
            }
            false
        }
    }
}

fn random_token() -> Result<String> {
    let mut bytes = [0u8; 24];
    getrandom::fill(&mut bytes).map_err(|e| anyhow!("the OS random generator: {e}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

static DAEMON_PREFIX: std::sync::OnceLock<Vec<std::ffi::OsString>> = std::sync::OnceLock::new();

/// Arguments placed before `daemon run` when a client starts the daemon, for
/// a host binary that runs acpmux under a subcommand (`cmux acp daemon run`).
/// Set once, before the first `connect`.
pub fn set_daemon_prefix(prefix: Vec<std::ffi::OsString>) {
    let _ = DAEMON_PREFIX.set(prefix);
}

/// The prefix set by [`set_daemon_prefix`]; agent hosts start with it too.
pub fn daemon_prefix() -> Vec<std::ffi::OsString> {
    DAEMON_PREFIX.get().cloned().unwrap_or_default()
}

/// How long a started daemon may take to report that its socket is bound.
const START_BUDGET: Duration = Duration::from_secs(8);

/// Wait until no daemon holds this home's lock (the running one exited),
/// at most `SHUTDOWN_BUDGET` plus a margin. True when it was released.
pub async fn wait_for_exit() -> bool {
    // The agents' budget, the router's stop and kill waits, and a margin.
    wait_for_lock_release(home().join("daemon.lock"), SHUTDOWN_BUDGET + Duration::from_secs(8))
        .await
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
    start_and_connect(&path, || Client::connect(&path)).await
}

/// A connected socket to the daemon, starting one if needed, for a client
/// that speaks the wire protocol itself (`acpmux stdio`).
pub async fn connect_stream() -> Result<crate::local_stream::Stream> {
    let path = socket_path();
    if let Ok(stream) = crate::local_stream::connect(&path).await {
        return Ok(stream);
    }
    start_and_connect(&path, || async { Ok(crate::local_stream::connect(&path).await?) }).await
}

/// How long a command waits for a daemon that holds the lock: a stopping one settles its agents
/// first (`SHUTDOWN_BUDGET`, the router's stop and kill waits; 12.3 s on cosmic-gray on
/// 2026-10-22), a starting one binds within `START_BUDGET`. The last start then has its own
/// `START_BUDGET`.
const HANDOVER_BUDGET: Duration = Duration::from_secs(20);

/// How often a command tries again while another daemon holds the lock.
const HANDOVER_RETRY: Duration = Duration::from_millis(250);

/// Starts a daemon and connects. When the started daemon found the lock taken (its readiness
/// line says `lockHeld`), another daemon is stopping (the app's handover to its bundled build,
/// `host update`, `daemon shutdown`) or starting: the command connects once that one serves, or
/// starts the next daemon once it has exited, instead of failing. Each try is a daemon start, so
/// the command never takes the lock itself and never makes a starting daemon lose it.
async fn start_and_connect<T, F, Fut>(path: &std::path::Path, connect: F) -> Result<T>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    exe_path::check_start()?;
    let deadline = tokio::time::Instant::now() + HANDOVER_BUDGET;
    loop {
        let ready = start_daemon().await?;
        let error = match connect().await {
            Ok(c) => return Ok(c),
            Err(e) => e,
        };
        if !lock_held(&ready) {
            return Err(not_ready(path, &ready, &error));
        }
        if tokio::time::Instant::now() + HANDOVER_RETRY >= deadline {
            return Err(anyhow!(
                "another acpmux daemon still holds {} after {HANDOVER_BUDGET:?} and serves no socket at {}; see {}",
                home().join("daemon.lock").display(),
                path.display(),
                home().join("daemon.log").display()
            ));
        }
        tokio::time::sleep(HANDOVER_RETRY).await;
        if let Ok(c) = connect().await {
            return Ok(c);
        }
    }
}

/// Whether a started daemon's readiness line says another daemon holds the lock.
fn lock_held(ready: &str) -> bool {
    serde_json::from_str::<Value>(ready.trim())
        .ok()
        .and_then(|v| v.get("lockHeld").and_then(Value::as_bool))
        == Some(true)
}

/// Start a daemon and wait until it reports readiness or exits. Returns its
/// readiness line (empty when it exited first).
#[cfg(unix)]
async fn start_daemon() -> Result<String> {
    start_daemon_with(None).await
}

/// `start_daemon`, with a person key for the daemon (`start_keyed`).
#[cfg(unix)]
async fn start_daemon_with(key: Option<zeroize::Zeroizing<String>>) -> Result<String> {
    let path = socket_path();
    // Outside the login session (an ssh client): the daemon goes to the user's GUI
    // session so its agents read the login keychain (`daemon/login_session.rs`). A
    // keyed start (the app's restart over ssh) stays here and says so.
    #[cfg(target_os = "macos")]
    {
        let this = crate::self_command::SelfCommand::current()?;
        crate::config::private_state_dir(&home())?;
        let log = home().join("daemon.log");
        drop(open_daemon_log(&log)?);
        let (home, keyed) = (home(), key.is_some());
        let placed = tokio::task::spawn_blocking(move || {
            login_session::start_in_login_session(&this, &home, &log, keyed)
        })
        .await
        .map_err(|e| anyhow!("{e}"))?;
        match placed {
            Ok(login_session::Started::Job(job)) => return wait_for_job(&path, job).await,
            Ok(login_session::Started::Running) => return Ok(LOCK_HELD_LINE.to_owned()),
            Ok(login_session::Started::No) => {}
            Ok(login_session::Started::NoGuiLogin) => {
                eprintln!("{}", login_placement::no_gui_login_warning());
                tracing::warn!("{}", login_placement::no_gui_login_warning());
            }
            Ok(login_session::Started::KeyedInPlace) => {
                eprintln!("{}", login_placement::keyed_in_place_warning());
                tracing::warn!("{}", login_placement::keyed_in_place_warning());
            }
            Err(e) => {
                let line = login_placement::start_failed_warning(&format!("{e:#}"));
                eprintln!("{line}");
                tracing::warn!("{line}");
            }
        }
    }
    // Async pipe I/O, so the timeout cancels the read; a blocking read on a
    // worker thread would keep runtime teardown waiting on a hung daemon.
    let ready = tokio::net::unix::pipe::Receiver::from_file(spawn_detached(key)?)
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
/// The readiness line of a daemon that found the lock taken (`run`).
#[cfg(target_os = "macos")]
const LOCK_HELD_LINE: &str = r#"{"ready":false,"lockHeld":true}"#;

/// A daemon started as launchd job `job` has no readiness pipe: its socket answering is its
/// readiness (an empty line; the caller connects). A job that ended before its socket answered
/// most likely found the lock taken by a daemon still stopping (`daemon shutdown`, `host
/// update`): that is reported as [`LOCK_HELD_LINE`], so `start_and_connect` waits for that
/// daemon within its handover budget and starts the next one, as it does for a daemon it
/// spawned. launchd is asked every half second, each answer bounded by what is left of
/// `START_BUDGET` (at most one second), so the wait never outlasts it by more than a poll.
#[cfg(target_os = "macos")]
async fn wait_for_job(path: &std::path::Path, job: String) -> Result<String> {
    let deadline = tokio::time::Instant::now() + START_BUDGET;
    let mut tries = 0u32;
    while tokio::time::Instant::now() < deadline {
        if tokio::net::UnixStream::connect(path).await.is_ok() {
            return Ok(String::new());
        }
        tries += 1;
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        if tries % 5 == 0 && !left.is_zero() {
            let job = job.clone();
            let budget = left.min(Duration::from_secs(1));
            let running =
                tokio::task::spawn_blocking(move || login_session::job_running(&job, budget))
                    .await
                    .unwrap_or(true);
            if !running && tokio::net::UnixStream::connect(path).await.is_err() {
                return Ok(LOCK_HELD_LINE.to_owned());
            }
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Err(anyhow!(
        "daemon did not come up at {} within {START_BUDGET:?}; see {}",
        path.display(),
        home().join("daemon.log").display()
    ))
}

/// Windows: CreateProcessW with a handle list (`daemon/windows.rs`).
#[cfg(windows)]
async fn start_daemon() -> Result<String> {
    windows::start_daemon(&home(), &daemon_prefix(), START_BUDGET).await
}

fn not_ready(path: &std::path::Path, ready: &str, error: &anyhow::Error) -> anyhow::Error {
    if let Some(refused) = exe_path::refused_line(ready) {
        return anyhow!("{refused}");
    }
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
#[cfg(unix)]
fn open_daemon_log(path: &std::path::Path) -> Result<std::fs::File> {
    crate::config::private_state_append(path)
}

#[cfg(all(test, unix))]
#[path = "daemon/state_file_tests.rs"]
mod state_file_tests;

/// Start `<exe> [prefix] daemon run --ready-fd N` in its own session and
/// return the read end of its readiness pipe. With `key`, the daemon also
/// gets `--person-key-fd M`, one end of a socket pair: the key is written
/// only after the daemon wrote [`KEY_READY`] on it.
#[cfg(unix)]
fn spawn_detached(key: Option<zeroize::Zeroizing<String>>) -> Result<std::fs::File> {
    let this = crate::self_command::SelfCommand::current()?;
    crate::config::private_state_dir(&home())?;
    let log = open_daemon_log(&home().join("daemon.log"))?;
    let log_err = log.try_clone()?;
    // Close-on-exec from the start (`pipe2(O_CLOEXEC)` where the OS has it):
    // a child another thread forks meanwhile never inherits either end, and
    // pre_exec reopens the write end for the daemon only.
    let (reader, writer) = std::io::pipe().context("pipe for acpmux daemon readiness")?;
    let reader = std::fs::File::from(std::os::fd::OwnedFd::from(reader));
    let write_fd = std::os::fd::AsRawFd::as_raw_fd(&writer);
    // The key's socket pair: `ours` stays here, `theirs` goes to the daemon.
    let pair = match &key {
        Some(_) => {
            let (ours, theirs) =
                std::os::unix::net::UnixStream::pair().context("socket pair for the person key")?;
            Some((ours, theirs))
        }
        None => None,
    };
    let key_fd = pair.as_ref().map(|(_, theirs)| std::os::fd::AsRawFd::as_raw_fd(theirs));
    let mut cmd = this.command(&["daemon", "run", "--ready-fd"]);
    crate::config::scrub_nested_claude_env(&mut cmd);
    // The daemon serves every session: its starter's turn values are not its own.
    for k in crate::config::inherited_caller_scoped_keys() {
        cmd.env_remove(k);
    }
    // The daemon must use this client's state directory and socket, including a host
    // override that its own environment would not reproduce, absolute: it changes into
    // its home before it binds (`login_placement::daemon_env`).
    let cwd = std::env::current_dir().context("this command's folder")?;
    let socket = std::env::var_os("ACPMUX_SOCKET");
    cmd.env_remove("ACPMUX_SOCKET");
    for (key, value) in login_placement::daemon_env(&home(), socket.as_deref(), &cwd) {
        cmd.env(key, value);
    }
    cmd.arg(write_fd.to_string())
        .args(key_fd.map(|fd| ["--person-key-fd".to_owned(), fd.to_string()]).into_iter().flatten())
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
                if let Some(fd) = key_fd {
                    libc::fcntl(fd, libc::F_SETFD, 0);
                }
                Ok(())
            });
        }
    }
    cmd.spawn().context("spawn acpmux daemon")?;
    // Close this process's copy so end of file means the daemon closed it.
    drop(writer);
    if let (Some(key), Some((ours, theirs))) = (key, pair) {
        drop(theirs);
        hand_key(ours, &key);
    }
    Ok(reader)
}

/// Write the key on the daemon's key socket after the daemon said it is
/// not dumpable, then close it. No signal (the daemon refused the key, or
/// exited): nothing is written, and the daemon runs without a key.
#[cfg(unix)]
fn hand_key(mut link: std::os::unix::net::UnixStream, key: &str) {
    use std::io::{Read, Write};
    let _ = link.set_read_timeout(Some(START_BUDGET));
    let mut said = [0u8; KEY_READY.len()];
    if link.read_exact(&mut said).is_err() || said != KEY_READY {
        tracing::warn!("the daemon did not say it is not dumpable: no person key was handed over");
        return;
    }
    let line = zeroize::Zeroizing::new(format!("{key}\n"));
    if let Err(e) = link.write_all(line.as_bytes()) {
        tracing::warn!("hand the person key to the daemon: {e}");
    }
    let _ = link.shutdown(std::net::Shutdown::Both);
}

/// The fixed dashboard port belongs to the shared daemon (`~/.acpmux`). Any other home (a
/// tagged dev build's, `ACPMUX_HOME`) listens on a free port and never saves the fixed one,
/// so it can never take the release daemon's port; a home that saved it before is moved off.
/// Returns the address to save: the saved one when it is fine, else the default.
fn first_run_listen(shared_home: bool, saved: Option<&str>) -> &str {
    const SHARED: &str = "127.0.0.1:47811";
    const ANY: &str = "127.0.0.1:0";
    match saved {
        Some(saved) if shared_home || !saved.ends_with(":47811") => saved,
        _ if shared_home => SHARED,
        _ => ANY,
    }
}
