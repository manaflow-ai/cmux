//! Daemon lifecycle: run the hub and listeners, or start a detached daemon
//! from a client command the way `tmux` starts its server on demand.

use crate::client::Client;
use crate::config::{Config, home, socket_path};
use crate::hub::Hub;
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use std::sync::{Arc, PoisonError};
use std::time::Duration;

pub(crate) mod exe_path;
mod lock;
#[cfg(unix)]
mod open_file_limit;
#[cfg(unix)]
pub(crate) use lock::socket_held_by_other;
use lock::{
    DaemonLock, LockHeld, acquire_lock, lock_has_live_holder, not_serving_recovery,
    wait_for_lock_release,
};
mod running;
pub use running::connect_running;
mod router_owner;
#[cfg(unix)]
pub(crate) use router_owner::open_router_owner;
pub(crate) use router_owner::router_owner_path;
use router_owner::{ensure_router, release_router};
mod app_orphan;
// Decided on every platform so its tests run everywhere; used on macOS only.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) mod login_placement;
#[cfg(target_os = "macos")]
pub(crate) mod login_session;
// Reports to the Cloud agent's socket, which only Cloud machines (Linux) have; decided on
// every Unix so its tests run on the Mac too.
#[cfg(unix)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod cloud_handoff;
mod handover;
mod home_watch;
mod notify;
pub(crate) mod owner_exit;
mod persist_retry;
#[cfg(unix)]
mod socket_rebind;
pub(crate) mod unused_exit;
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
    crate::cli::cloud_join::retain_own_machine_consent_requirement()?;
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
    // A capture fixture that cannot be read stops the start: a capture must
    // never show this host's harnesses in its place (`harness_fixture.rs`).
    crate::harness_fixture::check().map_err(|why| anyhow!(why))?;
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
    let _lock_file = match acquire_daemon_lock(&lock).await {
        Ok(lock) => lock,
        Err(e) => {
            // The command that started this daemon waits for the holder (`connect`).
            if let Some(fd) = opts.ready_fd.filter(|_| e.downcast_ref::<LockHeld>().is_some()) {
                // The app launches `daemon run` directly, without `start_and_connect`.
                // Its losing launch must report the winner's endpoint once it answers.
                tracing::info!("another daemon holds the lock; waiting for its socket or exit");
                match handover::wait(&home(), &socket_path()).await {
                    Some(handover::Started::Acquired(lock)) => lock,
                    Some(handover::Started::Ready(ready)) => {
                        write_ready(fd, &ready);
                        return Ok(());
                    }
                    None => {
                        write_ready(fd, &serde_json::json!({"ready": false, "lockHeld": true}));
                        return Err(e);
                    }
                }
            } else {
                return Err(e);
            }
        }
    };
    // The home and lock this daemon holds, read as soon as it holds them: one replaced during
    // the startup below is then a loss, never the watch's baseline (`daemon/home_watch.rs`).
    let owned_home = home_watch::Owned::now(&[&home(), &lock]);
    // Record the held home before any startup write, and start its watcher immediately. The
    // watcher marks a replacement before the later startup and shutdown paths can write there.
    crate::config::hold_home();
    let startup_home_gone =
        tokio::spawn(home_watch::watch(owned_home.clone(), None, &home(), &socket_path()));
    let _startup_home_watch = AbortOnDrop(startup_home_gone.abort_handle());
    // Gone already (removed between taking the lock and here): stop before the startup makes
    // anything there. A relative home is never watched (it reads as missing from the home cwd),
    // and there is no watch off Unix (`Owned::now` is always `None` there).
    if cfg!(unix) && owned_home.is_none() && home().is_absolute() {
        anyhow::bail!("the acpmux home {} went away as this daemon started", home().display());
    }
    // Deterministic startup replacement seam for the daemon lifecycle test. The held-home
    // identity fence rejects writes even before the asynchronous watcher receives its event.
    #[cfg(debug_assertions)]
    if std::env::var_os("ACPMUX_TEST_HOLD_AFTER_LOCK").is_some() {
        println!("acpmux-test-lock-held");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    crate::config::refuse_lost_home(&home())?;
    // The local CodeRouter relay (crate cmux-coderouter): `cmux-router` and `local-coderouter`
    // routes read its port and mint keys from it. Opt-in (the cmux app sets ACPMUX_LOCAL_ROUTER=1).
    // Its owner ties the router's life to this daemon (daemon/router_owner.rs: the owner FIFO,
    // shared with the agent hosts, on Unix; a kill-on-close job on Windows).
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
    let shared_home = uses_shared_home();
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
    // The socket as bound, read at once: the home watch and the shutdown's removal use it.
    let bound_socket = home_watch::Owned::now(&[&socket_path()]);
    // Gone already: nothing can reach this daemon, so it stops before the startup.
    if cfg!(unix) && bound_socket.is_none() && socket_path().is_absolute() {
        anyhow::bail!("the acpmux socket {} went away as it was bound", socket_path().display());
    }
    let mut moved_listener = false;
    let ws_listener = match &ws {
        // cx-fcaq: a taken explicit `--listen` stops the daemon (the caller asked for that
        // address). A taken configured port (an unrelated program, or a squatter) moves the daemon
        // to a free loopback port, which it reports and saves; the app reads the port from status
        // and checks its listener before it connects, and a proof names its transport, so a
        // squatter on the old port relays nothing.
        Some((listen, token)) => match crate::server::bind_ws(listen).await {
            Ok(l) => Some((l, token.clone())),
            Err(e) if explicit_listen => {
                remove_bound_socket(bound_socket.as_ref());
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
                        remove_bound_socket(bound_socket.as_ref());
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
    // Start one mesh before Hub starts its saved peers. It forwards only to
    // the WebSocket listener bound above, whose existing tokens remain mandatory.
    let wireguard = if config.transport.wireguard {
        let websocket =
            ws_listener.as_ref().context("WireGuard needs a WebSocket listener")?.0.local_addr()?;
        crate::wireguard::Transport::start(&config, &home(), websocket).await?
    } else {
        None
    };
    // Serve before reading session metadata or logs. Exact-id chat reads load on demand.
    let hub = Hub::new_loading_with_wireguard(config, store, mailbox, wireguard.clone());
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
    // The team hub's relay, when config.json names one (`server/mesh_relay.rs`).
    let mesh_relay = crate::server::mesh_relay::start_configured(&hub).await;
    // The Macs whose app may allow here over the peer link (`hub/mac_approvers.rs`).
    hub.person.macs.open(home().join(crate::hub::mac_approvers::FILE));
    if let Some(key) = person_key {
        // A Team-signed daemon takes the key only from the signed app's `_acpmux/person_enroll`: a
        // same-uid process could restart it with a key of its own.
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
    // (default 120, `hub::IDLE_CHILD`; 0 keeps every harness running).
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
    // A re-bound socket's listener takes the old one's place (`daemon/socket_rebind.rs`).
    #[cfg(unix)]
    let (rebound_tx, rebound_rx) = tokio::sync::mpsc::channel(1);
    #[cfg(unix)]
    let unix = tokio::spawn(socket_rebind::serve(hub.clone(), unix_listener, rebound_rx));
    #[cfg(not(unix))]
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
    let ws_shutdown = hub.ws_shutdown.clone();
    let ws_task = ws_listener.map(|(l, token)| {
        let auth = crate::server::WsAuth { local_app, peer };
        tokio::spawn(crate::server::serve_ws_until(
            hub.clone(),
            l,
            token,
            auth,
            ws_shutdown.clone(),
        ))
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
    // The stop signals are registered before the ready line: a launcher may stop the daemon as soon
    // as it reads the line, and a signal that came before registration would end the daemon by the
    // default action (no shutdown path: the token, pid file and socket would stay).
    #[cfg(unix)]
    let mut stop_signals = {
        use tokio::signal::unix::{SignalKind, signal};
        (signal(SignalKind::terminate()).ok(), signal(SignalKind::interrupt()).ok())
    };
    #[cfg(not(unix))]
    let ctrl_c = tokio::signal::ctrl_c();
    // A daemon whose cmux app is gone (`daemon/app_orphan.rs`); its bundle is
    // read before the ready line.
    // A memory store without agent hosts loses every chat on a stop, so a NIGHTLY or Release
    // daemon then never stops for its app (as `AcpmuxVersionHandoff` never restarts one).
    let app_orphan = app_orphan::watch(keeps_chats_across_stop(&hub, memory_store));
    // Before the ready line: a launcher may remove the home as soon as it reads it
    // (`daemon/home_watch.rs`). Its own task, so it keeps watching through a shutdown that began
    // on a signal: a home replaced while the agents drain is still marked lost before their last
    // writes. Ends with this function, whichever way it returns.
    let mut home_gone = tokio::spawn(home_watch::watch(
        owned_home.clone(),
        bound_socket.clone(),
        &home(),
        &socket_path(),
    ));
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut _home_watch = AbortOnDrop(home_gone.abort_handle());
    // The socket as last bound: a re-bind replaces it (`daemon/socket_rebind.rs`).
    let bound_socket = std::sync::Mutex::new(bound_socket);
    #[cfg(unix)]
    let mut rebinds = 0u32;
    // Unused for its grace on a home of its own, or soon after its owner app quit: a normal stop
    // (`daemon/unused_exit.rs`, `daemon/owner_exit.rs`).
    let mut unused = std::pin::pin!(unused_exit::unused(Arc::downgrade(&hub)));
    // Its home and lock, re-read during the shutdown too.
    #[cfg(unix)]
    let held_home = owned_home.clone();
    let recheck_home = move || {
        if let Some(why) = owned_home.as_ref().and_then(|owned| owned.lost()) {
            if !crate::config::home_lost() {
                tracing::warn!("shutting down: {why}");
            }
            crate::config::mark_home_lost();
        }
    };
    if let Some(fd) = opts.ready_fd {
        write_ready(fd, &ready);
    }
    // Debug builds only: `ACPMUX_TEST_HOLD_AFTER_READY_MS` holds the daemon right after the ready
    // line, so integration tests can stop it in that window. Bounded; release builds have no seam.
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
    // Metadata completion belongs to shutdown too; cancelling adoption must not cancel it.
    let metadata = {
        let hub = hub.clone();
        tokio::spawn(async move { hub.load_store_async().await })
    };
    hub.begin_startup_work();
    let startup = {
        let hub = hub.clone();
        tokio::spawn(async move {
            hub.wait_store().await;
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
            // An agent the previous daemon left, started from a profile changed since, restarts
            // on the new one between turns (`hub/profile_respawn.rs`).
            hub.spawn_profile_respawns();
            // After the login env import: it names harness homes.
            let sources = crate::chats::ChatSources::daemon(&*hub.config.read().await);
            if let Some(sources) = sources
                && let Err(e) = hub.start_chats(sources).await
            {
                tracing::warn!("{e}");
            }
            hub.end_startup_work();
        })
    };
    tokio::spawn(notify::notify_loop(hub.clone()));
    #[cfg(target_os = "linux")]
    tokio::spawn(cloud_handoff::handoff_loop(hub.clone()));

    #[cfg(all(unix, feature = "tailnet"))]
    let tailnet = crate::tailnet::embedded_service::Service::spawn(hub.clone());
    let shutdown = async {
        #[cfg(unix)]
        loop {
            let (term, int) = &mut stop_signals;
            tokio::select! {
                // Supervisors use SIGTERM for updates and permanent stops alike. Advertise
                // handoff: a stopped service causes one immediate retry, then normal backoff.
                _ = next_signal(term.as_mut()) => {
                    hub.restart_requested.store(true, std::sync::atomic::Ordering::SeqCst);
                },
                _ = next_signal(int.as_mut()) => {},
                _ = hub.shutdown.notified() => {},
                // No build of its app is left to adopt its agents, so they end with it. An app
                // that only quit or was updated keeps them, as its Quit does
                // (`daemon/app_orphan.rs`).
                end_agents = app_orphan => {
                    if end_agents {
                        let _ = hub.end_agents_at_shutdown(Default::default());
                    }
                },
                // A normal stop, not a restart handoff: nothing can reach this daemon again.
                // Except a loss of its socket alone: it binds that again and serves on, a
                // bounded number of times (`daemon/socket_rebind.rs`).
                Ok(lost) = &mut home_gone => match lost {
                    home_watch::Lost::Socket(why) if rebinds < socket_rebind::MAX_REBINDS => {
                        rebinds += 1;
                        match socket_rebind::rebind(held_home.as_ref(), &socket_path()).await {
                            Ok((listener, bound)) => {
                                tracing::warn!(
                                    "{why}; bound it again ({rebinds} of {})",
                                    socket_rebind::MAX_REBINDS
                                );
                                let _ = rebound_tx.send(listener).await;
                                home_gone = tokio::spawn(home_watch::watch(
                                    held_home.clone(),
                                    bound.clone(),
                                    &home(),
                                    &socket_path(),
                                ));
                                _home_watch = AbortOnDrop(home_gone.abort_handle());
                                *bound_socket.lock().unwrap_or_else(PoisonError::into_inner) =
                                    bound;
                                continue;
                            }
                            Err(e) => {
                                crate::config::mark_socket_lost();
                                tracing::warn!("stopping: {why}; binding it again failed: {e:#}");
                            }
                        }
                    }
                    home_watch::Lost::Socket(why) => {
                        crate::config::mark_socket_lost();
                        tracing::warn!("stopping: {why}, after {rebinds} re-binds");
                    }
                    home_watch::Lost::Stop(why) => tracing::warn!("stopping: {why}"),
                },
                why = &mut unused => tracing::info!("stopping: {why}"),
            }
            break;
        }
        #[cfg(not(unix))]
        {
            tokio::select! {
                _ = ctrl_c => {},
                _ = hub.shutdown.notified() => {},
                // No build of its app is left to adopt its agents, so they end with it. An app
                // that only quit or was updated keeps them, as its Quit does
                // (`daemon/app_orphan.rs`).
                end_agents = app_orphan => {
                    if end_agents {
                        let _ = hub.end_agents_at_shutdown(Default::default());
                    }
                },
                Ok(lost) = &mut home_gone => tracing::warn!("stopping: {lost:?}"),
                why = &mut unused => tracing::info!("stopping: {why}"),
            }
        }
    };
    tokio::select! {
        r = unix => { r??; }
        _ = shutdown => {}
    }
    tracing::info!("shutting down");
    // A home loss must request forced agent cleanup before the shutdown fence refuses changes
    // to the plan. A restart handoff keeps durable provider retries for the next daemon.
    recheck_home();
    let home_lost = crate::config::home_lost();
    if home_lost {
        let _ = hub.end_agents_at_shutdown(Default::default());
    }
    // Fence automatic continuations before any transport or metadata drain can yield to them.
    hub.begin_shutdown();
    // Fence tailnet supervision first: its ingress then ends through the
    // WebSocket shutdown below (1012 on restart), never as a listener failure.
    // A supervisor action under way finishes first, within its own bounds.
    #[cfg(all(unix, feature = "tailnet"))]
    tailnet.fence().await;
    // Its home is gone (`daemon/home_watch.rs`): no later daemon can adopt its agents from
    // there, so they end; and this shutdown removes nothing at the old paths, which may be
    // another daemon's now (`config::mark_home_lost` refuses its writes there).
    startup.abort();
    let _ = startup.await;
    // Its last heartbeat empties this daemon's rows in the hub's address book.
    if let Some(relay) = mesh_relay {
        let _ = tokio::time::timeout(std::time::Duration::from_secs(6), relay.stop()).await;
    }
    // SIGTERM handoff and explicit updates/restarts use 1012. Explicit ordinary RPC
    // shutdown and interactive interrupt use a normal WebSocket close.
    let restarting = hub.restart_requested.load(std::sync::atomic::Ordering::SeqCst);
    if restarting {
        ws_shutdown.restart();
    } else {
        ws_shutdown.normal_shutdown();
    }
    let drain_deadline = tokio::time::Instant::now() + crate::server::WS_DRAIN_BUDGET;
    if tokio::time::timeout_at(drain_deadline, ws_shutdown.drained()).await.is_err() {
        tracing::warn!("websocket listeners did not drain before the shutdown deadline");
    }
    if let Some(mut task) = ws_task
        && tokio::time::timeout_at(drain_deadline, &mut task).await.is_err()
    {
        task.abort();
        let _ = task.await;
        tracing::warn!("websocket clients did not drain before the shutdown deadline");
    }
    // The ingress has had the WebSocket drain to close its clients; stop and
    // join whatever remains within the service's own bound.
    #[cfg(all(unix, feature = "tailnet"))]
    tailnet.shutdown().await;
    // Keep encrypted bridges alive until WebSocket close/restart frames have drained.
    if let Some(transport) = wireguard {
        transport.shutdown(tokio::time::Instant::now() + SHUTDOWN_BUDGET).await;
    }
    // A node a person started closes with the daemon; its saved login stays.
    // The controller is made here if no request made it (it holds no node
    // until a start), so a start racing this shutdown is refused either way.
    #[cfg(all(unix, feature = "tailnet"))]
    match tokio::time::timeout(SHUTDOWN_BUDGET, hub.tailnet_controller().shutdown()).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => tracing::warn!("embedded tailnet close: {error}"),
        Err(_) => tracing::warn!("embedded tailnet did not close within {SHUTDOWN_BUDGET:?}"),
    }
    hub.stop_idle_reaper();
    // New clients get "connection refused" instead of a dying daemon. Only the socket this
    // daemon bound: one replaced since is another daemon's.
    recheck_home();
    // One that could not be read right after the bind is left alone: it may be another's. (A
    // replacement between this check and the unlink cannot be ruled out: unlink takes a path.)
    // Off Unix there is no identity to read: the socket goes, as it always did.
    let bound_socket = bound_socket.into_inner().unwrap_or_else(PoisonError::into_inner);
    if bound_socket.as_ref().map_or(!cfg!(unix), |s| s.lost().is_none()) {
        // The home watch runs on through the shutdown: this removal is not a loss.
        home_watch::release_socket();
        let _ = std::fs::remove_file(socket_path());
    }
    // How many hosted agents this shutdown kept running for the next
    // daemon; unknown (a timeout) counts as kept.
    let kept = match tokio::time::timeout(SHUTDOWN_BUDGET, async {
        // A signal can arrive while metadata loads. Snapshot every stored session before
        // detaching or ending hosts. A timeout conservatively keeps their router below.
        let _ = metadata.await;
        if restarting {
            hub.shutdown_all_with_auto_resume(true).await
        } else {
            hub.shutdown_all().await
        }
    })
    .await
    {
        Ok(kept) => kept,
        Err(_) => {
            tracing::warn!("agents did not stop within {SHUTDOWN_BUDGET:?}; exiting anyway");
            hub.flush();
            // As a shutdown that ends in time (`Hub::shutdown_all`): no write after this one.
            hub.seal();
            usize::MAX
        }
    };
    // After the agents: their model streams go through the router.
    // A lost home's router path may be another daemon's router now: let go of ours, never ask
    // that path to stop.
    // Read after the agents: the home may have been lost while they drained.
    recheck_home();
    let home_lost = crate::config::home_lost();
    let _ = tokio::task::spawn_blocking(move || release_router(kept == 0 && !home_lost)).await;
    // Cancelled and finished before the removal, so a late retry never puts it back.
    if let Some(retry) = pid_retry {
        retry.abort();
        let _ = retry.await;
    }
    recheck_home();
    if !crate::config::home_lost() {
        let _ = std::fs::remove_file(home().join("daemon.pid"));
        for file in [local_app_file, peer_file].into_iter().flatten() {
            let _ = std::fs::remove_file(file);
        }
    }
    tracing::info!("stopped");
    Ok(())
}

/// A startup that fails after the bind removes the socket only while it is still the one this
/// daemon bound: one replaced since is another daemon's. Off Unix there is no identity to read.
fn remove_bound_socket(bound: Option<&home_watch::Owned>) {
    if bound.map_or(!cfg!(unix), |s| s.lost().is_none()) {
        let _ = std::fs::remove_file(socket_path());
    }
}

/// Aborts a task when dropped.
struct AbortOnDrop(tokio::task::AbortHandle);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
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
pub(crate) const TOKEN_ROTATION: u32 = 1;

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

/// A systemd-owned daemon stays active while a previous daemon hands over this home.
/// This keeps `RestartPreventExitStatus=75` as a guard for detached starts without
/// making the supervised unit inactive during the ordinary handover window.
#[cfg(target_os = "linux")]
fn managed_by_acpmux_unit() -> bool {
    std::fs::read_to_string("/proc/self/cgroup")
        .ok()
        .is_some_and(|cgroup| cgroup.lines().any(|line| line.ends_with("/acpmux.service")))
}

#[cfg(not(target_os = "linux"))]
fn managed_by_acpmux_unit() -> bool {
    false
}

async fn acquire_daemon_lock(path: &std::path::Path) -> Result<DaemonLock> {
    loop {
        match acquire_lock(path) {
            Ok(lock) => return Ok(lock),
            Err(error)
                if managed_by_acpmux_unit() && error.downcast_ref::<LockHeld>().is_some() =>
            {
                if !wait_for_lock_release(path.to_owned(), Duration::from_secs(60)).await {
                    return Err(error);
                }
            }
            Err(error) => return Err(error),
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

/// How long a stopping daemon may take to exit: the agents' budget, the router's stop and kill
/// waits, and a margin.
pub const EXIT_BUDGET: Duration = SHUTDOWN_BUDGET.saturating_add(Duration::from_secs(8));

/// Wait until no daemon holds this home's lock (the running one exited),
/// at most [`EXIT_BUDGET`]. True when it was released.
pub async fn wait_for_exit() -> bool {
    wait_for_lock_release(home().join("daemon.lock"), EXIT_BUDGET).await
}

/// Connect to the daemon, starting one if needed.
pub async fn connect(autostart: bool) -> Result<Arc<Client>> {
    let home = home();
    let path = socket_path();
    connect_with_systemctl("systemctl", &home, &path, autostart, || Client::connect(&path)).await
}

/// Connect a trigger client without forwarding ambient session caller
/// credentials into the daemon connection.
pub async fn connect_without_caller(autostart: bool) -> Result<Arc<Client>> {
    let home = home();
    let path = socket_path();
    connect_with_systemctl("systemctl", &home, &path, autostart, || {
        Client::connect_without_caller(&path)
    })
    .await
}

/// A connected socket to the daemon, starting one if needed, for a client
/// that speaks the wire protocol itself (`acpmux stdio`).
pub async fn connect_stream() -> Result<crate::local_stream::Stream> {
    let home = home();
    let path = socket_path();
    connect_with_systemctl("systemctl", &home, &path, true, || async {
        Ok(crate::local_stream::connect(&path).await?)
    })
    .await
}

async fn connect_with_systemctl<S, T, F, Fut>(
    systemctl: S,
    current_home: &std::path::Path,
    path: &std::path::Path,
    autostart: bool,
    connect: F,
) -> Result<T>
where
    S: AsRef<std::ffi::OsStr> + Clone,
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    if let Ok(value) = connect().await {
        return Ok(value);
    }
    if !autostart {
        return Err(anyhow!("no acpmux daemon at {} (run `acpmux daemon`)", path.display()));
    }
    // Before the managed unit too: starting it would make a removed home again.
    if !EXPLICIT_START.load(std::sync::atomic::Ordering::Relaxed) {
        check_autostart(path)?;
    }
    if let Some(value) = managed_unit_connect_with(systemctl, current_home, path, &connect).await? {
        return Ok(value);
    }
    start_and_connect(path, connect).await
}

/// How long a command waits for a daemon that holds the lock: a stopping one settles its agents
/// first (`SHUTDOWN_BUDGET`, the router's stop and kill waits; 12.3 s on cosmic-gray on
/// 2026-10-22), a starting one binds within `START_BUDGET`. The last start then has its own
/// `START_BUDGET`.
pub const HANDOVER_BUDGET: Duration = Duration::from_secs(20);

// A detached start may wait for the old owner before binding its own socket.
// Keep its launcher alive through both phases, including the Windows pipe reader.
const READINESS_BUDGET: Duration = HANDOVER_BUDGET.saturating_add(START_BUDGET);

/// How often a command tries again while another daemon holds the lock.
const HANDOVER_RETRY: Duration = Duration::from_millis(250);

/// A CLI may be launched without the service's `ACPMUX_HOME` (for example,
/// from a session shell) while its daemon is owned by the user systemd unit.
/// In that case never call [`spawn_detached`]: the unit may use a supervised
/// state directory while the default home is a symlink, and the private-state
/// guard must continue to reject that symlink. Ask systemd to start its unit
/// and wait for the socket instead.
#[cfg(target_os = "linux")]
async fn managed_unit_connect_with<S, T, F, Fut>(
    systemctl: S,
    current_home: &std::path::Path,
    path: &std::path::Path,
    connect: &F,
) -> Result<Option<T>>
where
    S: AsRef<std::ffi::OsStr> + Clone,
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    const PROBE_BUDGET: Duration = Duration::from_secs(1);
    let show = tokio::process::Command::new(systemctl.clone())
        .args(["--user", "show", "acpmux.service", "-p", "LoadState", "--value"])
        .output();
    let loaded = match tokio::time::timeout(PROBE_BUDGET, show).await {
        Ok(Ok(output)) if output.status.success() => output.stdout.trim_ascii() == b"loaded",
        Ok(Ok(_)) => false,
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(Err(error)) => return Err(error.into()),
        Err(_) => {
            return Err(anyhow!("systemd did not report acpmux.service within {PROBE_BUDGET:?}"));
        }
    };
    if !loaded {
        return Ok(None);
    }

    let env = tokio::process::Command::new(systemctl.clone())
        .args(["--user", "show", "acpmux.service", "-p", "Environment", "--value"])
        .output();
    let env = match tokio::time::timeout(PROBE_BUDGET, env).await {
        Ok(Ok(output)) if output.status.success() => {
            String::from_utf8_lossy(&output.stdout).into_owned()
        }
        Ok(Ok(output)) => {
            return Err(anyhow!(
                "systemd could not read acpmux.service environment: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        Ok(Err(error)) => return Err(error.into()),
        Err(_) => {
            return Err(anyhow!(
                "systemd did not report acpmux.service environment within {PROBE_BUDGET:?}"
            ));
        }
    };
    let unit_home =
        unit_environment_path(&env, "ACPMUX_HOME").unwrap_or_else(crate::config::default_home);
    if !equivalent_path(current_home, &unit_home) {
        return Ok(None);
    }
    let unit_socket = unit_environment_path(&env, "ACPMUX_SOCKET");
    let expected_socket = crate::config::socket_path_for(
        &unit_home,
        unit_socket.as_deref().and_then(|path| path.to_str()),
    );
    if !equivalent_path(path, &expected_socket) {
        return Ok(None);
    }

    // A unit start can overlap the old daemon's graceful handover. Give the
    // unit the same bounded window clients use for that handover, rather than
    // failing after the shorter socket-bind budget while it still owns the
    // lock and is waiting for the old process to exit.
    let deadline = tokio::time::Instant::now() + HANDOVER_BUDGET;
    let mut last_start_error = None;
    let mut next_start = tokio::time::Instant::now();
    loop {
        if tokio::time::Instant::now() >= next_start {
            let start = tokio::process::Command::new(systemctl.clone())
                .args(["--user", "start", "acpmux.service"])
                .output();
            match tokio::time::timeout(PROBE_BUDGET, start).await {
                Ok(Ok(output)) if output.status.success() => last_start_error = None,
                Ok(Ok(output)) => {
                    last_start_error = Some(format!(
                        "systemd could not start acpmux.service: {}",
                        String::from_utf8_lossy(&output.stderr).trim()
                    ));
                }
                Ok(Err(error)) => last_start_error = Some(error.to_string()),
                Err(_) => {
                    last_start_error = Some(format!(
                        "systemd did not start acpmux.service within {PROBE_BUDGET:?}"
                    ))
                }
            }
            next_start = tokio::time::Instant::now() + HANDOVER_RETRY;
        }
        if let Ok(value) = connect().await {
            return Ok(Some(value));
        }
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        if left.is_zero() {
            return Err(anyhow!(last_start_error.unwrap_or_else(|| {
                format!(
                    "acpmux.service did not provide a socket at {} within {HANDOVER_BUDGET:?}",
                    path.display()
                )
            })));
        }
        tokio::time::sleep(HANDOVER_RETRY.min(left)).await;
    }
}

#[cfg(not(target_os = "linux"))]
async fn managed_unit_connect_with<S, T, F, Fut>(
    _systemctl: S,
    _current_home: &std::path::Path,
    _path: &std::path::Path,
    _connect: &F,
) -> Result<Option<T>>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    Ok(None)
}

#[cfg(target_os = "linux")]
fn unit_environment_path(environment: &str, key: &str) -> Option<std::path::PathBuf> {
    unit_environment_words(environment).into_iter().find_map(|entry| {
        entry
            .strip_prefix(key)
            .and_then(|value| value.strip_prefix('='))
            .map(std::path::PathBuf::from)
    })
}

#[cfg(target_os = "linux")]
fn unit_environment_words(environment: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut escaped = false;
    let mut has_word = false;
    for ch in environment.chars() {
        if escaped {
            word.push(ch);
            escaped = false;
            has_word = true;
            continue;
        }
        match quote {
            Some('"') if ch == '\\' => escaped = true,
            Some(q) if ch == q => quote = None,
            Some(_) => {
                word.push(ch);
                has_word = true;
            }
            None if ch == '\\' => escaped = true,
            None if ch == '\'' || ch == '"' => {
                quote = Some(ch);
                has_word = true;
            }
            None if ch.is_ascii_whitespace() => {
                if has_word {
                    words.push(std::mem::take(&mut word));
                    has_word = false;
                }
            }
            None => {
                word.push(ch);
                has_word = true;
            }
        }
    }
    if escaped {
        word.push('\\');
        has_word = true;
    }
    if has_word {
        words.push(word);
    }
    words
}

#[cfg(target_os = "linux")]
fn equivalent_path(left: &std::path::Path, right: &std::path::Path) -> bool {
    fn normalized(path: &std::path::Path) -> Option<std::path::PathBuf> {
        std::fs::canonicalize(path).ok().or_else(|| {
            let parent = path.parent()?;
            Some(std::fs::canonicalize(parent).ok()?.join(path.file_name()?))
        })
    }
    left == right || normalized(left).zip(normalized(right)).is_some_and(|(l, r)| l == r)
}

/// Starts a daemon and connects. When the started daemon found the lock taken (its readiness
/// line says `lockHeld`), another daemon is stopping or starting: the command connects once that
/// one serves, or starts the next daemon once it has exited.
async fn start_and_connect<T, F, Fut>(path: &std::path::Path, connect: F) -> Result<T>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    if !EXPLICIT_START.load(std::sync::atomic::Ordering::Relaxed) {
        check_autostart(path)?;
    }
    exe_path::check_start()?;
    // The lock's holder serves this home at another socket: a start would wait out its own
    // handover for it (`handover::wait`), and no wait makes it serve this one.
    if let Some(other) = holder_elsewhere(path).await {
        return Err(serves_elsewhere(path, &other));
    }
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
        // The lock's holder serves this home at another socket: no wait makes it serve this one.
        if let Some(other) = holder_elsewhere(path).await {
            return Err(serves_elsewhere(path, &other));
        }
        if tokio::time::Instant::now() + HANDOVER_RETRY >= deadline {
            return Err(anyhow!(
                "another acpmux daemon still holds {} after {HANDOVER_BUDGET:?} and serves no socket at {}{}; see {}",
                home().join("daemon.lock").display(),
                path.display(),
                not_serving_recovery(&home().join("daemon.lock")),
                home().join("daemon.log").display()
            ));
        }
        tokio::time::sleep(HANDOVER_RETRY).await;
        if let Ok(c) = connect().await {
            return Ok(c);
        }
    }
}

/// Set by `acpmux daemon start`: the person asked for a daemon in this home and at this socket,
/// so [`check_autostart`] (for commands that start one only to be served) does not apply.
static EXPLICIT_START: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// This command is `acpmux daemon start` (see [`EXPLICIT_START`]).
pub fn mark_explicit_start() {
    EXPLICIT_START.store(true, std::sync::atomic::Ordering::Relaxed);
}

/// Refuses a start whose home or socket cannot be this command's daemon's
/// ([`crate::config::autostart_refusal`]).
fn check_autostart(path: &std::path::Path) -> Result<()> {
    let home = home();
    let configured =
        std::env::var_os("ACPMUX_SOCKET").filter(|v| !v.is_empty()).map(|_| path.to_path_buf());
    #[cfg(unix)]
    let own = crate::config::socket_path_for(&home, None);
    // Windows derives its pipe path its own way; only the missing-home rule applies there.
    #[cfg(not(unix))]
    let own = path.to_path_buf();
    match crate::config::autostart_refusal(
        &home,
        std::env::var_os("ACPMUX_HOME").is_some(),
        configured.as_deref(),
        &own,
    ) {
        Some(why) => Err(anyhow!(why)),
        None => Ok(()),
    }
}

/// The refusal when this home's daemon serves `other`, not `path`.
fn serves_elsewhere(path: &std::path::Path, other: &std::path::Path) -> anyhow::Error {
    anyhow!(
        "the acpmux daemon that holds {} serves {}, not {}; unset ACPMUX_SOCKET or set it to {}",
        home().join("daemon.lock").display(),
        other.display(),
        path.display(),
        other.display()
    )
}

/// The socket a daemon of this home serves, when it is not `path`: the socket its lock records
/// (`lock::holder_socket`), else the home's own, once the daemon answering there says in its
/// status that it is this home's (`home`, `socket`).
#[cfg(unix)]
async fn holder_elsewhere(path: &std::path::Path) -> Option<std::path::PathBuf> {
    let home = home();
    let mut candidates = Vec::new();
    for socket in lock::holder_socket(&home.join("daemon.lock"))
        .into_iter()
        .chain([crate::config::socket_path_for(&home, None)])
    {
        if socket != path && !candidates.contains(&socket) {
            candidates.push(socket);
        }
    }
    for socket in candidates {
        // The connect too: a stopped (suspended) daemon accepts and never answers `initialize`.
        let asked = tokio::time::timeout(START_BUDGET, async {
            let client = Client::connect(&socket).await?;
            client.request(crate::rpc::method::MUX_STATUS, serde_json::json!({})).await
        })
        .await;
        let Ok(Ok(status)) = asked else { continue };
        let serves =
            |key: &str| status.get(key).and_then(Value::as_str).map(std::path::PathBuf::from);
        if serves("home").as_deref() == Some(home.as_path())
            && let Some(serving) = serves("socket").filter(|s| s != path)
        {
            return Some(serving);
        }
    }
    None
}

#[cfg(not(unix))]
async fn holder_elsewhere(_path: &std::path::Path) -> Option<std::path::PathBuf> {
    None
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
    match tokio::time::timeout(READINESS_BUDGET, wait).await {
        Ok(read) => Ok(read.unwrap_or_default()),
        Err(_) => Err(anyhow!(
            "daemon did not come up at {} within {READINESS_BUDGET:?}; see {}",
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
        if tries.is_multiple_of(5) && !left.is_zero() {
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
    windows::start_daemon(&home(), &daemon_prefix(), READINESS_BUDGET).await
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

#[cfg(target_os = "linux")]
fn cgroup_is_in_sessions_scope(contents: &str) -> bool {
    contents.lines().filter_map(|line| line.splitn(3, ':').nth(2)).any(|path| {
        path.split('/').any(|component| component == crate::session_scope::SESSIONS_SLICE)
    })
}

#[cfg(target_os = "linux")]
fn daemon_started_in_session_scope() -> bool {
    std::fs::read_to_string("/proc/self/cgroup")
        .is_ok_and(|contents| cgroup_is_in_sessions_scope(&contents))
}

#[cfg(target_os = "linux")]
fn daemon_command(this: &crate::self_command::SelfCommand) -> std::process::Command {
    if daemon_started_in_session_scope()
        && let Some(runner) = crate::session_scope::scope_runner()
        && crate::session_scope::can_make_scope(&runner)
    {
        let mut command = std::process::Command::new(runner);
        command.args([
            "--user",
            "--scope",
            "--quiet",
            "--collect",
            "--no-block",
            "--description=acpmux daemon",
            "--",
        ]);
        command.arg(&this.exe).args(&this.prefix).args(["daemon", "run", "--ready-fd"]);
        return command;
    }
    this.command(&["daemon", "run", "--ready-fd"])
}

#[cfg(not(target_os = "linux"))]
fn daemon_command(this: &crate::self_command::SelfCommand) -> std::process::Command {
    this.command(&["daemon", "run", "--ready-fd"])
}

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
    let mut cmd = daemon_command(&this);
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
    // A daemon a command starts has no owner app: only the app's launcher names one
    // (`daemon/owner_exit.rs`), so a CLI run from an agent or a harness never ties the new daemon
    // to the app that started an older one.
    cmd.env_remove(owner_exit::OWNER_APP_PID_ENV);
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
    let mut child = tokio::process::Command::from(cmd).spawn().context("spawn acpmux daemon")?;
    // A lock-race loser exits promptly. Reap it even when its CLI caller keeps
    // running (stdio/TUI); dropping std::process::Child left a zombie per retry.
    // This async wait never holds runtime teardown open or kills the winner.
    tokio::spawn(async move {
        let _ = child.wait().await;
    });
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

/// Use the same home classification for initial launch and CLI restart.
pub(crate) fn uses_shared_home() -> bool {
    dirs::home_dir().map(|h| h.join(".acpmux")) == Some(home())
}

/// The fixed dashboard port belongs to the shared daemon (`~/.acpmux`). Any other home (a
/// tagged dev build's, `ACPMUX_HOME`) listens on a free port and never saves the fixed one,
/// so it can never take the release daemon's port; a home that saved it before is moved off.
/// Returns the address to save: the saved one when it is fine, else the default.
pub(crate) fn first_run_listen(shared_home: bool, saved: Option<&str>) -> &str {
    const SHARED: &str = "127.0.0.1:47811";
    const ANY: &str = "127.0.0.1:0";
    match saved {
        Some(saved) if shared_home || !saved.ends_with(":47811") => saved,
        _ if shared_home => SHARED,
        _ => ANY,
    }
}

/// Whether a stop keeps this daemon's chats: agents under agent hosts (as the hub runs them,
/// never for a memory store, whatever `ACPMUX_AGENT_HOSTS` says), or chats on disk. The
/// app-orphan watch never stops a NIGHTLY or Release daemon without it.
fn keeps_chats_across_stop(hub: &Hub, memory_store: bool) -> bool {
    hub.agent_hosts_enabled() || !memory_store
}

#[cfg(test)]
mod keeps_chats_tests {
    use super::*;
    use crate::config::StoreMode;

    fn hub(mode: StoreMode, dir: &std::path::Path) -> std::sync::Arc<Hub> {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = mode;
        let store = crate::store::open(&cfg.store, dir).unwrap();
        let hub = Hub::new(cfg, store);
        // What `run` does with the default environment (no `ACPMUX_AGENT_HOSTS=0`).
        hub.enable_agent_hosts();
        hub
    }

    #[test]
    fn a_memory_daemon_with_the_default_env_keeps_no_chats_across_a_stop() {
        let dir = tempfile::tempdir().unwrap();
        // `--memory`, default env: agent hosts asked for, but a memory store never runs them,
        // so the app-orphan watch must never stop it (its chats would be lost).
        let memory = hub(StoreMode::Memory, dir.path());
        assert!(!memory.agent_hosts_enabled());
        assert!(!keeps_chats_across_stop(&memory, true));
        let local = hub(StoreMode::Local, dir.path());
        assert!(keeps_chats_across_stop(&local, false));
    }
}

#[cfg(all(test, target_os = "linux"))]
mod scope_tests {
    use super::cgroup_is_in_sessions_scope;

    #[test]
    fn daemon_scope_escape_matches_only_an_exact_session_slice_component() {
        assert!(cgroup_is_in_sessions_scope(
            "0::/user.slice/user-1000.slice/user@1000.service/acpmuxsessions.slice/run-a.scope\n"
        ));
        assert!(!cgroup_is_in_sessions_scope(
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-a.scope\n"
        ));
        assert!(!cgroup_is_in_sessions_scope(
            "0::/user.slice/acpmuxsessions.slice.backup/run-a.scope\n"
        ));
        assert!(cgroup_is_in_sessions_scope(
            "1:name=systemd:/user.slice/acpmuxsessions.slice/run-a.scope\n"
        ));
    }
}
