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
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(crate) mod exe_swap;
mod lock;
#[cfg(unix)]
mod log_cap;
#[cfg(unix)]
mod open_file_limit;
#[cfg(unix)]
pub(crate) use lock::live_holder_pid;
#[cfg(unix)]
pub(crate) use lock::socket_held_by_other;
use lock::{
    DaemonLock, LockHeld, acquire_lock, lock_has_live_holder, same_path, wait_for_lock_release,
    wait_for_lock_release_with_budget,
};
mod running;
pub use running::connect_running;
mod snapshot_clear;
pub(crate) mod start_exe;
pub(crate) use snapshot_clear::clear_peer_snapshots;
mod router_owner;
pub(crate) use router_owner::router_owner_path;
use router_owner::{ensure_router, release_router};
mod app_orphan;
pub(crate) use app_orphan::in_dev_bundle;
#[cfg(unix)]
pub(crate) use app_orphan::is_app_acpmux;
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
// Counts this daemon's chats at work toward the Cloud machine's activity (idle pause).
#[cfg(unix)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod cloud_activity;
#[cfg(all(test, unix))]
pub(crate) use cloud_activity::probe as cloud_activity_probe;
// Connect to the daemon, or start one and connect (the client side).
mod connect;
use connect::*;
pub use connect::{
    connect, connect_stream, connect_without_caller, mark_explicit_start, saved_start_refusal,
};
mod handover;
mod home_watch;
#[cfg(unix)]
pub(crate) mod listener_handover;
mod managed_unit;
// A launchd job's start stands by while another daemon holds its home (`daemon/launchd_standby.rs`).
mod launchd_standby;
// A take-over start yields to a successor of its own build (`daemon/take_over_yield.rs`).
mod take_over_yield;
use managed_unit::managed_unit_connect_with;
mod take_over;
use take_over::{acquire_daemon_lock, managed_by_acpmux_unit};
mod token_rotation;
pub(crate) use token_rotation::TOKEN_ROTATION;
use token_rotation::{random_token, rotate_saved_token_once};
mod detached_spawn;
#[cfg_attr(not(unix), allow(unused_imports))]
pub(crate) use detached_spawn::STARTER_SESSION_MARKS;
#[cfg(unix)]
pub(crate) use detached_spawn::log_start_choice;
#[cfg(unix)]
use detached_spawn::{daemon_command, hand_key};
mod notify;
pub(crate) use crate::daemon_parts::first_run_listen;
pub use crate::daemon_parts::{daemon_prefix, set_daemon_prefix};
pub(crate) use crate::owner_exit;
/// A process's start time, which with its pid names it (the test owner, `owner_exit.rs`).
pub use owner_exit::process_start;
mod persist_retry;
mod person_key;
// A retired build's sooner stop and the clearing of dead daemons' records (`daemon/prune.rs`).
#[cfg(unix)]
pub(crate) mod prune;
#[cfg(unix)]
pub(crate) use crate::daemon_parts::not_dumpable;
#[cfg(unix)]
use person_key::KEY_READY;
// Only the Linux provisioning exec (provision::enroll_running) reads a key line from here.
#[cfg(target_os = "linux")]
pub(crate) use person_key::read_key_line;
use person_key::read_person_key;
#[cfg(unix)]
pub use person_key::start_keyed;
// The provisioning exec's person key for the running daemon (Cloud machines).
#[cfg(unix)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) mod provision;
#[cfg(unix)]
mod socket_rebind;
mod stop_causes;
mod stop_watchdog;
pub(crate) use stop_watchdog::shutdown_time_left;
pub(crate) mod supervision;
#[cfg(unix)]
pub(crate) use crate::term_sender;
#[cfg(unix)]
use stop_causes::next_signal;
use stop_causes::{AbortOnDrop, store_asks_to_stop};
pub use stop_causes::{EXIT_REPAIR, exit_status};
#[cfg(target_os = "linux")]
mod restart_backoff;
pub(crate) mod unused_exit;
#[cfg(target_os = "linux")]
mod watchdog;
#[cfg(windows)]
mod windows;

pub struct DaemonOptions {
    pub ws_listen: Option<String>,
    pub ws_token: Option<String>,
    /// `--insecure-network-listen`: bind a network (non-loopback) listen
    /// address this run, as `websocket.allowInsecureNetwork` does.
    pub insecure_network_listen: bool,
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
    /// `--take-over`: this daemon is the home's supervised owner (the systemd unit); it takes
    /// the home over from another daemon that serves the same socket ([`take_over_holder`]).
    pub take_over: bool,
}

pub use crate::config::panic_log_path;

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
    if std::env::var(TEST_PANIC_ENV).as_deref() == Ok("thread") {
        let _ = std::thread::Builder::new()
            .name(TEST_PANIC_THREAD.into())
            .spawn(|| test_panic("acpmux test panic"));
    }
}

/// Debug builds and unit tests: the one panic the test triggers raise (below, and the agent host's
/// translator seam, `agent_host/host.rs` `test_translator_panic`).
#[cfg(any(test, debug_assertions))]
#[allow(
    clippy::panic,
    reason = "debug-build and test-build trigger for the acpmux panic log; release builds have no seam"
)]
pub(crate) fn test_panic(message: &str) -> ! {
    // crash-allow: debug-only test trigger for the acpmux panic log
    panic!("{message}");
}

/// Debug builds only: `ACPMUX_TEST_PANIC=<task>` makes that task of the daemon panic
/// (tests/panic_log.rs).
#[cfg(debug_assertions)]
fn test_panic_in(task: &str) {
    if std::env::var(TEST_PANIC_ENV).as_deref() == Ok(task) {
        test_panic(&format!("acpmux test panic in {task}"));
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

/// How often a WireGuard transport that holds the key lock asks whether the cmux link now
/// serves the node key (`Transport::yield_to_link`): a few file reads.
const LINK_HANDOFF_EVERY: Duration = Duration::from_secs(2);

/// How long SIGTERM or `_acpmux/shutdown` may take before the daemon exits
/// anyway.
/// The complete handoff budget after the daemon has announced shutdown. Remote links and
/// cancellation-ignoring hub tasks are cut at this deadline so the next daemon can bind promptly.
pub const SHUTDOWN_BUDGET: Duration = Duration::from_secs(1);

/// The shutdown's budget once its plan is fixed: [`SHUTDOWN_BUDGET`] for a restart handoff,
/// and the agents' ends on top when the shutdown ends them (Quit Everything): a cut there
/// leaves an agent running with no daemon to end it (Codex review of #42296).
pub(crate) fn shutdown_budget(ends_agents: bool) -> Duration {
    if ends_agents {
        SHUTDOWN_BUDGET.saturating_add(crate::hub::AGENT_END_BUDGET)
    } else {
        SHUTDOWN_BUDGET
    }
}

/// `exit_tasks` belongs to the CLI and stays alive until process exit. Shutdown persistence
/// may use the end of that lifetime while retaining this daemon's exclusive home lock.
pub async fn run(opts: DaemonOptions, exit_tasks: &cmux_scope::Scope) -> Result<()> {
    stop_watchdog::reset();
    // The start of every startup phase in `daemon status` is timed from (`gauges.rs`).
    let gauges = crate::gauges::global();
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
    // A Cloud machine's daemon, which the provisioning exec may give the key later: not dumpable for
    // its whole run, from before anything is spawned (`daemon/provision.rs`).
    #[cfg(unix)]
    provision::at_start();
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
    // Opt-in usage patterns (cmux-usage-patterns): counts nothing until the person turns on
    // `diagnostics.usagePatterns`. Counts and kinds only, never prompt or tool text.
    let _ = cmux_usage_patterns::install("acpmux");
    // Opt-in install-count sharing (`install_share.rs`): sends nothing until the person turns on
    // `diagnostics.shareInstallCounts`, and never calls the platform for a person who never did.
    crate::install_share::start();
    // Opt-in team usage sharing (cmux-usage-share): records nothing and sends nothing until the
    // person turns on `diagnostics.usageSharing` and acknowledges the notice
    // (`diagnostics.usageSharingNoticeAck`). One record per turn: counts, times and hashed
    // ids, never prompt, tool or file text.
    let _ = cmux_usage_share::install(&home(), Some(crate::hand::pair::hostname()));
    // Before the store, the sockets and any agent: launchd's soft limit is 256.
    #[cfg(unix)]
    open_file_limit::raise();
    let load_config = || -> Result<Config> {
        let mut config = Config::load()?;
        // config.json holds the dashboard token: owner-only, also when another
        // tool wrote it with the umask's mode and the daemon never saves it.
        narrow_to_owner(&Config::path());
        config.dev_origins = dev_origins.clone();
        crate::login_env::set_extra_allow(config.login_env_allow.clone());
        if opts.memory {
            config.store.mode = crate::config::StoreMode::Memory;
        }
        Ok(config)
    };
    let config = load_config()?;
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
    // Debug builds only: a daemon a test started stops with that test's process, mid-turn too
    // (`daemon/owner_exit.rs`); never in a release build. Armed before the lock wait, which has no
    // limit while the holder lives, so a test that dies during it ends this daemon too.
    let mut test_owner = std::pin::pin!(owner_exit::test_owner_exit());
    #[cfg(unix)]
    handover::reclaim_from_dev(&lock, &socket_path(), &home()).await;
    // None: another daemon answers for this home and its ready line went out; nothing to do.
    let lock_wait = async {
        match acquire_daemon_lock(&lock, opts.take_over, opts.ready_fd.is_none()).await {
            Ok(lock) => Ok(Some(lock)),
            Err(e) => {
                // A take-over start whose home a daemon of its own build already serves: nothing to
                // hand over; it answers its launcher with that daemon and exits.
                if let Some(served) = e.downcast_ref::<take_over_yield::ServedByThisBuild>() {
                    tracing::info!(
                        "{served}; this take-over start exits without asking it to hand over"
                    );
                    if let Some(fd) = opts.ready_fd {
                        write_ready(fd, &served.ready);
                    }
                    return Ok(None);
                }
                // The command that started this daemon waits for the holder (`connect`).
                if let Some(fd) = opts.ready_fd.filter(|_| e.downcast_ref::<LockHeld>().is_some()) {
                    // The app launches `daemon run` directly, without `start_and_connect`.
                    // Its losing launch must report the winner's endpoint once it answers.
                    tracing::info!("another daemon holds the lock; waiting for its socket or exit");
                    match handover::wait(&home(), &socket_path()).await {
                        Some(handover::Started::Acquired(lock)) => Ok(Some(lock)),
                        Some(handover::Started::Ready(ready)) => {
                            write_ready(fd, &ready);
                            Ok(None)
                        }
                        None => {
                            write_ready(fd, &serde_json::json!({"ready": false, "lockHeld": true}));
                            Err(e)
                        }
                    }
                } else {
                    Err(e)
                }
            }
        }
    };
    let _lock_file = tokio::select! {
        lock = lock_wait => match lock? {
            Some(lock) => lock,
            None => return Ok(()),
        },
        pid = &mut test_owner => {
            tracing::warn!("stopping before it held its lock: its test process {pid} exited");
            return Ok(());
        }
    };
    // config.json again, now that this daemon holds the home: the lock wait has no limit (launchd's
    // start waits for the app's daemon for as long as the app runs), and the copy read before it
    // could carry a token rotated since or settings changed since, which the listener would serve
    // and the token write below would save over the newer file.
    let mut config = load_config()?;
    // The home and lock this daemon holds, read as soon as it holds them: one replaced during
    // the startup below is then a loss, never the watch's baseline (`daemon/home_watch.rs`).
    let owned_home = home_watch::Owned::now(&[&home(), &lock]);
    // Record the held home before any startup write, and start its watcher immediately. The
    // watcher marks a replacement before the later startup and shutdown paths can write there.
    crate::config::hold_home();
    // Its output file stays bounded: past the cap, this run starts a new one (`log_cap.rs`).
    #[cfg(unix)]
    match log_cap::rotate_at_start(&home().join("daemon.log"), log_cap::CAP) {
        Ok(true) => {
            tracing::info!("daemon.log was past {} MiB: moved to daemon.log.1", log_cap::CAP >> 20)
        }
        Ok(false) => {}
        Err(e) => tracing::warn!("daemon.log could not be moved aside: {e:#}"),
    }
    let startup_home_gone =
        tokio::spawn(home_watch::watch(owned_home.clone(), None, &home(), &socket_path()));
    let _startup_home_watch = AbortOnDrop(startup_home_gone.abort_handle());
    // Forwards a dead acpmux process left open (killed before its drop ran): ended by their
    // recorded owner, never found by name (`ssh_forward_owners.rs`). One pass, off the workers.
    {
        let ledger = crate::ssh_forward_owners::ledger_dir(&home());
        tokio::task::spawn_blocking(move || {
            let reaped =
                crate::ssh_forward_owners::reap_recorded(std::ffi::OsStr::new("ssh"), &ledger);
            if reaped.ended > 0 {
                tracing::info!(
                    ended = reaped.ended,
                    kept = reaped.kept,
                    "ended leftover ssh forwards"
                );
            }
        });
    }
    // Gone already (removed between taking the lock and here): stop before the startup makes
    // anything there. A relative home is never watched (it reads as missing from the home cwd),
    // and there is no watch off Unix (`Owned::now` is always `None` there).
    if cfg!(unix) && owned_home.is_none() && home().is_absolute() {
        anyhow::bail!("the acpmux home {} went away as this daemon started", home().display());
    }
    // The owner record right after the lock, before the socket: a client that dials while this
    // start has not bound yet reads a live owner and waits for it (`connect_when_ready`), and the
    // previous owner's end is settled (a death counted) once.
    supervision::start(&home());
    // The update watch's baseline (F9, `daemon/exe_swap.rs`), taken now: an update that lands
    // between ready and the later startup is then a change it sees, never its baseline.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    let exe_watch = exe_swap::watch(std::env::args().skip(1).collect());
    // Deterministic startup replacement seam for the daemon lifecycle test. The held-home
    // identity fence rejects writes even before the asynchronous watcher receives its event.
    #[cfg(debug_assertions)]
    if std::env::var_os("ACPMUX_TEST_HOLD_AFTER_LOCK").is_some() {
        println!("acpmux-test-lock-held");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    crate::config::refuse_lost_home(&home())?;
    // `machine-auth` reads the env its agents start with from this record, never from /proc.
    if let Err(e) = crate::cli::machine_auth::record_daemon_env(&home()) {
        tracing::warn!("could not record the daemon's agent env: {e}");
    }
    // Bind before durable startup work, so clients can connect independently of journal replay.
    // Requests wait for the hub and launch tokens; agent spawns wait for `finish_startup`.
    // A take-over serves the listeners the daemon it took over from handed it
    // (`daemon/listener_handover.rs`): the same sockets, whose queues never closed.
    #[cfg(unix)]
    let handed = listener_handover::take_received();
    #[cfg(unix)]
    let unix_listener = match handed.unix {
        Some(l)
            if listener_handover::serves_path(&l, &socket_path())
                && socket_path().exists()
                && l.set_nonblocking(true).is_ok() =>
        {
            tracing::info!(
                "serving {} handed over by the previous daemon",
                socket_path().display()
            );
            tokio::net::UnixListener::from_std(l)?
        }
        _ => crate::server::bind_unix(&socket_path()).await?,
    };
    #[cfg(not(unix))]
    let unix_listener = crate::server::bind_unix(&socket_path()).await?;
    // The v2 handle is created only after the listener is ready. Its empty
    // published index is filled by the list tee in the follow-up lane; startup
    // never waits on this handle or on a chat book.
    let mut v2_tasks = tokio::task::JoinSet::new();
    let v2 = v2_handle(&config);
    if let Some(v2) = v2.as_ref()
        && let Some(writer) = v2.take_writer()
    {
        v2_tasks.spawn(async move {
            if let Err(error) = writer.run().await {
                tracing::warn!(%error, "v2 hub writer stopped");
            }
        });
    }
    // The socket as bound, read at once: the home watch and the shutdown's removal use it.
    let bound_socket = home_watch::Owned::now(&[&socket_path()]);
    // Gone already: nothing can reach this daemon, so it stops before the startup.
    if cfg!(unix) && bound_socket.is_none() && socket_path().is_absolute() {
        anyhow::bail!("the acpmux socket {} went away as it was bound", socket_path().display());
    }
    // Binding depends only on daemon ownership and listener configuration. Opening the
    // journal scans checkpoint files and replays records, so no per-chat store work belongs
    // before this boundary. Requests still wait for the hub and this launch's auth tokens.
    let _socket_cleanup = BoundSocketCleanup(bound_socket.clone());
    gauges.mark("socket ready");
    // Under systemd's watchdog: pings only while this socket answers hello (`daemon/watchdog.rs`).
    #[cfg(target_os = "linux")]
    watchdog::start(socket_path());
    // The local CodeRouter relay (crate cmux-coderouter): `cmux-router` and `local-coderouter`
    // routes read its port and mint keys from it. Opt-in (the cmux app sets ACPMUX_LOCAL_ROUTER=1).
    // Its owner ties the router's life to this daemon (daemon/router_owner.rs: the owner FIFO,
    // shared with the agent hosts, on Unix; a kill-on-close job on Windows).
    if std::env::var("ACPMUX_LOCAL_ROUTER").as_deref() == Ok("1") {
        ensure_router();
    }
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
        let (allowed_origins, allowed_hosts, allow_insecure_network) = config
            .websocket
            .as_ref()
            .map(|w| (w.allowed_origins.clone(), w.allowed_hosts.clone(), w.allow_insecure_network))
            .unwrap_or_default();
        config.websocket = Some(crate::config::WebSocketConfig {
            listen: first_run_listen(shared_home, saved_listen.as_deref()).to_owned(),
            token: Some(kept_token.map_or_else(random_token, Ok)?),
            allowed_origins,
            allowed_hosts,
            // A kept token was rotated just above; a new one is new.
            token_rotated: TOKEN_ROTATION,
            allow_insecure_network,
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

    // The rest of config.json's start check (`config/start_check.rs`), the one `config --set` and
    // `_acpmux/reload_config` run, so the CLI never writes what is refused here. The listener is
    // checked just below, where `--listen` may stand in for config.json's.
    if let Err(e) = config.settings_refusal() {
        if let Some(fd) = opts.ready_fd {
            write_ready(fd, &serde_json::json!({"ready": false, "refused": format!("{e:#}")}));
        }
        return Err(e);
    }
    // Plain ws:// on a network address sends the token in clear: only with
    // the person's opt-in, on every path below (`server/ws_auth.rs`).
    let allow_network = opts.insecure_network_listen
        || config.websocket.as_ref().is_some_and(|w| w.allow_insecure_network);
    if let Some((listen, _)) = &ws {
        let from = if explicit_listen { "--listen" } else { "websocket.listen" };
        if let Err(e) = crate::server::check_listen_address(listen, allow_network).await {
            let e = e.context(format!("refusing {from} {listen}"));
            // Said where the person sees it: the launcher shows the readiness line's refusal
            // (the app's daemon-start failure notice, `daemon start`), not only this log.
            if let Some(fd) = opts.ready_fd {
                write_ready(fd, &serde_json::json!({"ready": false, "refused": format!("{e:#}")}));
            }
            return Err(e);
        }
    }

    let store = crate::store::open(&config.store, &home())?;
    crate::mcp_gateway::start(&home()).await; // before any session starts
    #[cfg(unix)]
    crate::mcp_pool::start(&home()).await;
    let mut moved_listener = false;
    // The handed web listener, when it is bound where this start would bind (and the address
    // still passes the listener rule above); otherwise closed before the bind below.
    #[cfg(unix)]
    let handed_ws = handed.ws.and_then(|l| {
        let (listen, _) = ws.as_ref()?;
        let want: std::net::SocketAddr = listen.parse().ok()?;
        let bound = l.local_addr().ok()?;
        if bound != want || want.port() == 0 || l.set_nonblocking(true).is_err() {
            return None;
        }
        tokio::net::TcpListener::from_std(l).ok()
    });
    #[cfg(not(unix))]
    let handed_ws: Option<tokio::net::TcpListener> = None;
    let ws_listener = match (&ws, handed_ws) {
        (Some((listen, token)), Some(l)) => {
            tracing::info!("web + websocket serving {listen} handed over by the previous daemon");
            Some((l, token.clone()))
        }
        // cx-fcaq: a taken explicit `--listen` stops the daemon (the caller asked for that
        // address). A taken configured port (an unrelated program, or a squatter) moves the daemon
        // to a free loopback port, which it reports and saves; the app reads the port from status
        // and checks its listener before it connects, and a proof names its transport, so a
        // squatter on the old port relays nothing.
        (Some((listen, token)), None) => match crate::server::bind_ws_with(listen, allow_network)
            .await
        {
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
        (None, _) => None,
    };
    // `--listen 127.0.0.1:0` asked for any free port; report the real one.
    let bound_addr = ws_listener.as_ref().and_then(|(l, _)| l.local_addr().ok());
    // The cmux link carries paired peers' `acpmux` streams only to the listener this record
    // names while this daemon runs (`listener_record.rs`), never to config.json's port.
    // The guard removes it on every way out: a startup error after this returns through `?`,
    // and the shutdown drops it first, while the listener is still bound.
    let listener_record = match bound_addr.map(|addr| crate::listener_record::write(&home(), addr))
    {
        Some(Ok(written)) => Some(written),
        Some(Err(e)) => {
            tracing::warn!("could not record the web listener for the cmux link: {e}");
            None
        }
        None => None,
    };
    let bound = bound_addr.map(|a| a.to_string());
    if let (Some(addr), Some((_, token))) = (&bound, &ws) {
        let (allowed_origins, allowed_hosts, allow_insecure_network) = config
            .websocket
            .as_ref()
            .map(|w| (w.allowed_origins.clone(), w.allowed_hosts.clone(), w.allow_insecure_network))
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
            allow_insecure_network,
        });
        // The new port is this home's port from now on.
        if moved_listener && let Err(e) = config.save() {
            tracing::warn!("could not save the moved web listener: {e}");
        }
    }
    let mailbox = crate::mailbox::Mailbox::open(home().join("mailbox"))?;
    let memory_store = config.store.mode == crate::config::StoreMode::Memory;
    // A machine credential copied here from another box (`cli/cloud_join/host_fingerprint.rs`)
    // is marked cloned and this box gets its own node key, before the WireGuard transport and
    // the mesh relay read either.
    // Off the async workers: it may wait a bounded while for the join lock.
    let settled = tokio::task::spawn_blocking(crate::cli::cloud_join::settle_clone_at_start)
        .await
        .unwrap_or_else(|e| Err(anyhow!("clone check task: {e}")));
    let clone_unsettled = match settled {
        Ok(crate::cli::cloud_join::CloneCheck::Cloned) => {
            tracing::warn!(
                "machine credential was copied from another machine: not used here; this machine has a new node key. Paste a new join line to join it."
            );
            false
        }
        Ok(_) => false,
        Err(e) => {
            // The copied node key could not be replaced: keep this box off WireGuard for this
            // run rather than answer with the original's identity.
            // Includes a node key recorded as copied (a leave removed the record).
            let copied = crate::cli::cloud_join::copied_from_another_box();
            tracing::warn!(copied, "machine clone check failed: {e:#}");
            copied
        }
    };
    if clone_unsettled {
        tracing::warn!(
            "WireGuard transport off for this run: this home was copied from another machine"
        );
        tracing::warn!("hub carrier off for this run: this home was copied from another machine");
    }
    // Start one mesh before Hub starts its saved peers. It forwards only to
    // the WebSocket listener bound above, whose existing tokens remain mandatory.
    let wireguard = if config.transport.wireguard && !clone_unsettled {
        let websocket =
            ws_listener.as_ref().context("WireGuard needs a WebSocket listener")?.0.local_addr()?;
        crate::wireguard::Transport::start(&config, &home(), websocket).await?
    } else {
        None
    };
    // Started before the cmux link was set up here, the transport holds this machine's key
    // lock: it hands it to the link once one serves this home's node key (`cmux link ensure`
    // waits for it, `key_lock.rs`).
    if let Some(transport) = wireguard.clone() {
        tokio::spawn(async move {
            transport.yield_to_link(&home(), LINK_HANDOFF_EVERY, SHUTDOWN_BUDGET).await;
        });
    }
    // Serve before reading session metadata or logs. Exact-id chat reads load on demand.
    let hub = Hub::new_loading_with_wireguard(config, store, mailbox, wireguard.clone());
    if let Some(v2) = v2.as_ref() {
        let (tee, task) = crate::hub::list_tee::start_v2_tee(hub.clone(), v2.clone());
        hub.install_v2_tee(tee);
        // Links carry the list stream only with `list` and `peers` in the set (`link_v2.rs`).
        hub.link_v2.install(v2.clone());
        v2.hub.set_page_provider(std::sync::Arc::new(crate::hub::list_tee::V1PageProvider::new(
            hub.clone(),
        )));
        v2_tasks.spawn(task);
        // The book tee (`hub/book_tee.rs`): its drain and background pass, never awaited here.
        if let Some(registry) = v2.registry() {
            let (tee, task) = crate::hub::book_tee::start_book_tee(hub.clone(), registry.clone());
            hub.install_book_tee(tee);
            v2_tasks.spawn(task);
        }
    }
    // A copied machine's first start settles what the logs left open as stopped
    // (`hub/clone_boot.rs`); read before any log is.
    let cloned = hub.take_clone_marker(&home()).is_some();
    // The forum log (`forum.rs`): on disk unless the store is in memory; a
    // log that cannot open leaves the posts in memory.
    // Place modes' cutoff, before anything is answered: a chat made before it with no pin reads
    // as pinned here, one made after as Auto (`place_pin.rs`). Some: this home's one-time
    // migration, run after the store loads (below).
    let place_migration =
        if memory_store { None } else { crate::place_pin::start(&home(), crate::store::now_ms()) };
    if !memory_store && let Err(e) = hub.open_forum(&home().join("forum")) {
        tracing::warn!("forum log unavailable, keeping posts in memory: {e:#}");
    }
    // Messages `send --no-wait` handed over (`hub/outbox.rs`): saved beside the sessions, and
    // what a restart left undelivered goes on.
    if !memory_store {
        // A copy's first start delivers none of them: the machine it was copied from does. Its
        // outbox is set aside (kept for a look, never read again) and this one starts empty.
        if cloned {
            let path = home().join("outbox.json");
            let journal = crate::hub::outbox::journal_path(&path);
            // The journal first: a start cut short between the two never reads the copied
            // journal over an empty snapshot.
            for (from, to) in
                [(journal, "outbox.journal.clone-boot"), (path, "outbox.json.clone-boot")]
            {
                if let Err(e) = crate::home_fs::rename(&from, home().join(to))
                    && e.kind() != std::io::ErrorKind::NotFound
                {
                    tracing::warn!("copied machine's outbox not set aside: {e}");
                }
            }
        }
        let pending = hub.outbox.open(&home().join("outbox.json"));
        // A delivery that ends failed bounces to its sender (`hub/dead_letters.rs`).
        hub.start_bounces();
        crate::hub::register::load_registered();
        // Whatever the rename did: a rename that failed leaves the copied outbox in place, and
        // none of it is this machine's to deliver.
        if !cloned {
            crate::server::outbox::resume(&hub, pending);
        }
        hub.watches.open(&home().join("watches.json"));
    }
    hub.start_watches();
    // What the join in config.json starts (`server/machine_enroll.rs`): the team hub's relay
    // (`server/mesh_relay.rs`), kept on the hub so a sign-in enroll can start one live, and the
    // hub carrier on the same hub and credential (`hub_carrier.rs`), through which this machine
    // serves its relay slot and its peers dial it. A copied home runs no carrier, as WireGuard.
    // A sign-out's leave the last run did not finish goes first: neither starts for a machine
    // that left.
    let carrier = (!clone_unsettled)
        .then(|| ws_listener.as_ref().and_then(|(l, _)| l.local_addr().ok()))
        .flatten();
    crate::server::machine_enroll::start_joined_at_start(&hub, carrier).await;
    // A machine joined before the hub recorded capabilities states them with its own credential,
    // in the background (`cli/cloud_join/self_capabilities.rs`); the start never waits for it.
    crate::cli::cloud_join::state_capabilities_at_start(&hub.scope);
    // A joined Mac's daemon serves screen shares with no app running (`share_host/`).
    #[cfg(target_os = "macos")]
    crate::share_host::start(&hub.scope);
    // A joined Linux machine's is cmux-rd's, which the daemon sets up here in the background
    // (`share_host/linux.rs`): its join needs no step on the machine.
    #[cfg(target_os = "linux")]
    if !clone_unsettled {
        crate::share_host::linux::start(&hub.scope);
    }
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
    // The curated model catalog (`catalog/`): the last good copy now, then a fetch of it and
    // of the public model feed at once and every hour. `ACPMUX_CATALOG_FETCH=0` keeps the
    // stored or bundled copy and reads no feed.
    let fetch_catalog = !std::env::var("ACPMUX_CATALOG_FETCH").is_ok_and(|v| v == "0");
    let fetcher: Option<std::sync::Arc<dyn crate::catalog::Fetcher>> =
        fetch_catalog.then(|| std::sync::Arc::new(crate::catalog::HttpsFetcher::current()) as _);
    hub.catalog.attach(home().join("catalog"), fetcher);
    if fetch_catalog {
        hub.catalog.attach_feed(std::sync::Arc::new(crate::catalog::feed::FeedFetcher::default()));
    }
    if fetch_catalog {
        let catalog = hub.catalog.clone();
        crate::supervise::restarting("catalog", &hub.fatal, move || catalog.clone().run());
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
            peer_scratch: None,
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
    // Each session's disk use against its budget (`hub/session_budget_watch.rs`); off with
    // ACPMUX_SESSION_DISK_WATCH=0.
    hub.start_session_budget_watch();
    // Idle chats off this machine while it stays over budget: only with `autoEvacuate.enabled`
    // (off by default); off runs no timer (`hub/auto_evacuate.rs`).
    hub.start_auto_evacuate().await;
    // A dead lane on a peer tells the session here that started it, once per death
    // (`hub/lane_death_watch.rs`); off with ACPMUX_LANE_DEATH_WATCH=0.
    hub.start_lane_death_watch();
    // Placed work yields when the owner comes back: only on a machine enrolled in AutoCloud
    // (off by default); off runs no timer (`hub/owner_return.rs`).
    hub.start_owner_return().await;
    // `dynamic` sessions yield the CPU only while the Mac is contended (`hub/cpu_pressure.rs`);
    // ACPMUX_CPU_PRESSURE=off keeps every one at normal class.
    hub.start_cpu_pressure();
    // The host's sender token, which our own tools present to be named verified
    // (`sender_token.rs`): made once, kept across restarts. Without it no send is verified by it,
    // as before, so a failure is only logged.
    if let Err(e) = crate::sender_token::ensure(&home()) {
        tracing::warn!("the host sender token: {e}");
    }
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
    // Debug builds only: `ACPMUX_TEST_DELAY_LOCAL_APP_MS` holds the daemon right before it makes
    // this launch's LocalApp token, so a test can ask the unix socket in that window. Bounded;
    // release builds have no seam.
    #[cfg(debug_assertions)]
    if let Some(ms) =
        std::env::var("ACPMUX_TEST_DELAY_LOCAL_APP_MS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        tokio::time::sleep(Duration::from_millis(ms.min(5_000))).await;
    }
    // A new LocalApp token at every launch (`server/local_app.rs`), for the
    // app's bundled pane and an explicit `--allow-dev-origin` page only.
    // Written before the unix socket serves: the app reads the WebSocket endpoint from
    // `_acpmux/status` there and then this file, so a pane reconnecting the moment a restarted
    // daemon answers read no token (or the previous launch's) and stayed remote-origin for its
    // whole life (Leo, 2026-11-12: his own Claude chat refused on his own Mac). The peer token
    // likewise, for a peer that reads it after asking this daemon.
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
    // A new peer token at every launch (`server/peer_auth.rs`), read by a peer over ssh only.
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
    // A re-bound socket's listener takes the old one's place (`daemon/socket_rebind.rs`).
    #[cfg(unix)]
    let (rebound_tx, rebound_rx) = tokio::sync::mpsc::channel(1);
    // Copies to hand a take-over start (`daemon/listener_handover.rs`).
    #[cfg(unix)]
    {
        use std::os::fd::AsFd as _;
        listener_handover::offer(
            unix_listener.as_fd(),
            ws_listener.as_ref().map(|(l, _)| l.as_fd()),
        );
    }
    #[cfg(unix)]
    let unix =
        tokio::spawn(socket_rebind::serve(hub.clone(), unix_listener, rebound_rx, v2.clone()));
    // The connections the previous daemon had accepted and handed over (`server/conn_handover.rs`):
    // served as the ones accepted above.
    #[cfg(unix)]
    if let Some(side) = handed.conns {
        let (hub, v2) = (hub.clone(), v2.clone());
        listener_handover::receive_connections(side, move |stream| {
            crate::server::serve_accepted(hub.clone(), stream, v2.clone());
        });
    }
    #[cfg(not(unix))]
    let unix = tokio::spawn(crate::server::serve_unix(hub.clone(), unix_listener));
    let local_app_file = local_app.as_ref().map(|a| a.path().to_owned());
    let peer_file = peer.as_ref().map(|a| a.path().to_owned());
    let carrier_file = crate::server::carrier::start(&hub, &home()).await;
    // A fleet host takes a new channel build within a minute (`cli/host_update_watch.rs`), only
    // from the daemon `acpmux.service` runs: one in another home (a test's, a second daemon's) leaves it.
    if home() == crate::config::default_home() {
        hub.scope.spawn_until_cancelled("channel watch", crate::cli::hosts::watch_channel());
    }
    let ws_shutdown = hub.ws_shutdown.clone();
    // Opt-in (`CMUX_TAILNET_CARRIER`): peers of this person's tailnet may also reach the same
    // port on this machine's tailnet address, whois-admitted (`tailnet_carrier.rs`).
    let tailnet_mode = crate::tailnet_carrier::Mode::from_env();
    if let (Some(addr), Some((_, token)), true) =
        (bound_addr, ws_listener.as_ref(), tailnet_mode != crate::tailnet_carrier::Mode::Off)
    {
        hub.scope.spawn_until_cancelled(
            "tailnet peers",
            crate::tailnet_carrier::serve_peers(
                hub.clone(),
                addr.port(),
                token.clone(),
                crate::server::WsAuth { local_app: local_app.clone(), peer: peer.clone() },
                ws_shutdown.clone(),
                tailnet_mode,
                crate::tailnet_carrier::Gate::cli(),
            ),
        );
    }
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
    gauges.mark("requests ready");
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
        let term = signal(SignalKind::terminate()).ok();
        // Who sends SIGTERM is named on the stop line (`daemon/term_sender.rs`). Only once tokio's
        // own stream is registered: an action of ours alone would replace SIGTERM's default
        // action, and a daemon whose stream failed would then never stop on SIGTERM.
        if term.is_some() {
            term_sender::record();
        }
        (term, signal(SignalKind::interrupt()).ok())
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
    // A retired build (its executable gone) stops after a shorter unused wait (`daemon/prune.rs`).
    let mut unused = std::pin::pin!(unused_exit::unused(Arc::downgrade(&hub), memory_store));
    // Records of daemons that died, cleared on a timer while this daemon runs (`daemon/prune.rs`).
    #[cfg(unix)]
    let prune_scope = cmux_scope::Scope::new("daemon prune");
    #[cfg(unix)]
    prune_scope.spawn_until_cancelled("daemon prune", prune::every_while_running());
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
    // Remote ssh handshakes are background work. Give the first local initialize and chat attach
    // a turn before dialing them; otherwise a god-sized peer fan-out can starve the pane after
    // the socket is already ready.
    // A daemon that serves for a minute resets its unit's restart delay (`daemon/restart_backoff.rs`).
    #[cfg(target_os = "linux")]
    restart_backoff::start(&hub.scope);
    {
        let peers = hub.clone();
        hub.scope.spawn_until_cancelled("peer-start-gate", async move {
            tokio::select! {
                _ = peers.wait_local_ready() => {}
                _ = tokio::time::sleep(Duration::from_secs(2)) => {}
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
            peers.start_saved_peers().await;
        });
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
        let loading = hub.clone();
        crate::supervise::once("store load", &hub.fatal, async move {
            let _phase = gauges.phase("store load");
            loading.load_store_async().await;
        })
    };
    hub.begin_startup_work();
    let startup = {
        let (hub, fatal) = (hub.clone(), hub.fatal.clone());
        // A startup that panicked can never finish: the daemon stops for a restart.
        crate::supervise::once("startup", &fatal, async move {
            {
                let _phase = gauges.phase("wait for store");
                hub.wait_store().await;
            }
            // The list's kept order first, before any log is read (`list_order.rs`): a list page
            // or usage pass that comes before the logs are read waits for this sort alone, not
            // for adoption and every log as well. After the ready line, so start stays instant.
            {
                let _phase = gauges.phase("list order");
                let sorting = hub.clone();
                if let Err(e) = tokio::task::spawn_blocking(move || sorting.sort_list_order()).await
                {
                    tracing::error!("sorting the list order failed: {e}");
                }
            }
            // Place modes: every chat older than them is pinned to this machine, once, so
            // nothing moves unasked (`hub/place_migrate.rs`). Beside the rest of the start, never
            // in front of it: one saved pin per chat, thousands of chats on a busy Mac. Until it
            // ends, a chat with no pin reads as pinned here. A later start finds the marker.
            if let Some(cutoff) = place_migration {
                let migrating = hub.clone();
                tokio::task::spawn_blocking(move || {
                    migrating.migrate_place_modes(&home(), cutoff);
                });
            }
            #[cfg(debug_assertions)]
            test_panic_in("startup");
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
            // Debug builds only: hold the live-log/adoption boundary for tests that prove a
            // request does not wait on global startup. Release builds have no seam.
            #[cfg(debug_assertions)]
            if std::env::var_os("ACPMUX_TEST_HOLD_STARTUP").is_some() {
                let held = tokio::task::spawn_blocking(|| {
                    crate::hub::test_hold("ACPMUX_TEST_HOLD_STARTUP")
                });
                let _ = held.await;
            }
            // What an agent start needs (login environment, catalog, launcher checks, vault)
            // runs beside the chats: a new chat waits for it alone, and a chat's own start for it
            // and its own adoption, never for every host's adoption (`hub/startup.rs`).
            let chats = async {
                // Agents that outlived the previous daemon come back first: their chats' logs
                // (tails, queues), then adoption. Every other chat's log is read in the background
                // after it, or first by a request for that chat (`hub/log_load.rs`).
                {
                    let _adopted = crate::hub::AdoptionReady(&hub.adoption_ready);
                    let _phase = gauges.phase("live chat logs");
                    hub.load_live_logs_async().await;
                    drop(_phase);
                    let _phase = gauges.phase("adopt agent hosts");
                    hub.adopt_agent_hosts().await;
                    drop(_phase);
                    let _phase = gauges.phase("settle unadopted");
                    hub.settle_unadopted().await;
                }
                {
                    let _phase = gauges.phase("recover workflows");
                    hub.recover_workflows().await;
                }
                {
                    let hub = hub.clone();
                    hub.clone().scope.spawn_until_cancelled("restore-chat-logs", async move {
                        {
                            let _phase = gauges.phase("all chat logs");
                            hub.load_logs_async().await;
                        }
                        if hub.shutting_down() {
                            return;
                        }
                        hub.finish_clone_boot(&home());
                        // Once every log is read: a pass reads only chats whose log is loaded.
                        let _worker = hub.retention_worker();
                        // A chat's sealed segments go cold as they seal (`cold_segments.rs`).
                        let _cold_segments = hub.cold_segments_worker();
                        // A chat's pack seals a segment as its log grows (`pack_as_it_grows.rs`).
                        let _packs = hub.pack_as_it_grows_worker();
                        // Archives inactive chats when set (`hub/inactive_archive.rs`).
                        hub.inactive_archive_worker();
                        // Every chat's held messages, once every log is read: a deadline wake the
                        // restart lost is armed again, and what no turn can take expires back to
                        // its sender (`hub/inbox_deadline.rs`).
                        let _deadlines = hub.inbox_deadline_worker();
                    });
                }
                // A chat a machine's Full-access setting moved out of its policy's mode goes back:
                // a revoke the previous daemon saved may not have reached it (`crate::pairing`).
                // A chat started before this runs in its policy's mode already (`hold_policy_mode`).
                let _phase = gauges.phase("hold policies");
                hub.hold_policies_again().await;
            };
            let (reloaded, ()) = tokio::join!(hub.prepare_spawns(), chats);
            {
                let _phase = gauges.phase("finish startup");
                hub.finish_startup_after_prepare(reloaded).await;
            }
            // An agent the previous daemon left, started from a profile changed since or running
            // from a binary that an update moved, restarts on the profile and binary installed now,
            // between turns (`hub/profile_respawn.rs`, `hub/stale_host_respawn.rs`).
            hub.spawn_startup_respawns();
            // Until shutdown aborts this task, on every path (a signal too).
            hub.run_after_startup().await;
        })
    };
    {
        let hub = hub.clone();
        crate::supervise::restarting("notify", &hub.fatal.clone(), move || {
            notify::notify_loop(hub.clone())
        });
    }
    let weak = Arc::downgrade(&hub);
    // A paused machine or a stopped daemon is noticed on resume (`hub/resume.rs`).
    {
        let weak = weak.clone();
        crate::supervise::restarting("resume", &hub.fatal, move || Hub::resume_loop(weak.clone()));
    }
    // Chats settle on their own by `agents.autoSettle.*` (`hub/auto_settle.rs`).
    {
        let weak = weak.clone();
        crate::supervise::restarting("auto-settle", &hub.fatal, move || {
            Hub::auto_settle_loop(weak.clone())
        });
    }
    // Claude and Codex desktop sessions listed as chats, while `agents.desktopBridge.enabled`
    // (`hub/desktop_bridge.rs`).
    crate::supervise::restarting("desktop bridge", &hub.fatal, move || {
        Hub::desktop_bridge_loop(weak.clone())
    });
    // How late this runtime wakes a task (`gauges.workerLag` in `daemon status`): a worker held by
    // blocking work shows here before requests time out. Ended with the hub's scope.
    let _worker_lag = hub.scope.spawn_until_cancelled(
        "worker-lag-canary",
        crate::gauges::worker_lag_canary(crate::gauges::worker_lag()),
    );
    // Supervised: a panic starts the loop again (`crate::supervise`).
    #[cfg(target_os = "linux")]
    {
        let hub = hub.clone();
        crate::supervise::restarting("cloud hand-off", &hub.fatal.clone(), move || {
            cloud_handoff::handoff_loop(hub.clone())
        });
    }
    // Opt-in team usage sharing's uploads (`server/chats/team_audit.rs`); idle while it is off.
    let _usage_upload = hub.scope.spawn_until_cancelled(
        "usage-share-upload",
        crate::server::usage_upload_loop(hub.settings_changes.subscribe()),
    );
    #[cfg(target_os = "linux")]
    {
        let hub = hub.clone();
        crate::supervise::restarting("cloud activity", &hub.fatal.clone(), move || {
            cloud_activity::activity_loop(hub.clone())
        });
    }
    // Auto mode's holder loop on a laptop (`auto_session/laptop.rs`). It asks the Cloud once for
    // the person's Auto chats this laptop does not have, then nothing until a chat has Auto on.
    #[cfg(unix)]
    let _auto_session = crate::auto_session::laptop::start(hub.clone());
    // An update that moves this executable away swaps to the installed build, make-before-break
    // (F9, `daemon/exe_swap.rs`). Ended with the runtime.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    let _exe_watch = hub.scope.spawn_until_cancelled("exe-swap-watch", exe_watch);

    #[cfg(all(unix, feature = "tailnet"))]
    let tailnet = crate::server::tailnet_service::Service::spawn(hub.clone());
    // The store asks for a restart when it cannot go on safely (`Store::stop_reason`): a frozen
    // event journal checkpoint, whose logs only the next start's replay writes again.
    let mut store_stop = std::pin::pin!(store_asks_to_stop(hub.clone()));
    let shutdown = async {
        // Every stop names its cause in the log (`app_orphan` and `unused` name their own).
        #[cfg(unix)]
        let mut app_orphan = std::pin::pin!(app_orphan);
        #[cfg(unix)]
        loop {
            let (term, int) = &mut stop_signals;
            tokio::select! {
                // Supervisors use SIGTERM for updates and permanent stops alike. Advertise
                // handoff: a stopped service causes one immediate retry, then normal backoff.
                _ = next_signal(term.as_mut()) => {
                    let from = term_sender::settled().await.map(term_sender::describe);
                    match &from {
                        Some(from) => tracing::warn!("stopping: SIGTERM from {from} (a restart handoff)"),
                        None => tracing::warn!("stopping: SIGTERM (a restart handoff)"),
                    }
                    supervision::stopping(cmux_supervise_core::StopCause::Intentional(format!(
                        "SIGTERM from {}",
                        from.as_deref().unwrap_or("an unknown sender")
                    )));
                    hub.restart_requested.store(true, std::sync::atomic::Ordering::SeqCst);
                },
                _ = next_signal(int.as_mut()) => {
                    tracing::warn!("stopping: SIGINT");
                    supervision::stopping(cmux_supervise_core::StopCause::Intentional("SIGINT".into()));
                },
                _ = hub.shutdown.notified() => tracing::warn!("stopping: a client asked it to"),
                // A restart handoff: the next start repairs what the store could not.
                () = &mut store_stop => {},
                // No build of its app is left to adopt its agents, so they end with it. An app
                // that only quit or was updated keeps them, as its Quit does
                // (`daemon/app_orphan.rs`).
                end_agents = &mut app_orphan => {
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
                                {
                                    use std::os::fd::AsFd as _;
                                    listener_handover::offer_unix(listener.as_fd());
                                }
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
                        supervision::stopping(cmux_supervise_core::StopCause::SelfStop(why.to_string()));
                    }
                    home_watch::Lost::Stop(why) => {
                        tracing::warn!("stopping: {why}");
                        supervision::stopping(cmux_supervise_core::StopCause::SelfStop(why.to_string()));
                    }
                },
                why = &mut unused => {
                    tracing::info!("stopping: {why}");
                    supervision::stopping(cmux_supervise_core::StopCause::Intentional(why.to_string()));
                },
                // Nothing can use its agents now: they end with it, hosts and harnesses too.
                pid = &mut test_owner => {
                    tracing::warn!("stopping: its test process {pid} exited");
                    let _ = hub.end_agents_at_shutdown(Default::default());
                },
            }
            break;
        }
        #[cfg(not(unix))]
        {
            tokio::select! {
                _ = ctrl_c => {},
                _ = hub.shutdown.notified() => {},
                () = &mut store_stop => {},
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
                pid = &mut test_owner => {
                    tracing::warn!("stopping: its test process {pid} exited");
                    let _ = hub.end_agents_at_shutdown(Default::default());
                },
            }
        }
    };
    let unix_accept = unix.abort_handle();
    tokio::select! {
        r = unix => { r??; }
        _ = shutdown => {}
    }
    tracing::info!("shutting down");
    // Handed its listeners to the daemon that takes over (`daemon/listener_handover.rs`): it
    // stops accepting now, so every connect from here on waits in the queue the new daemon
    // serves; the connections it has are answered (`shutdown_drain`) and closed as a restart
    // (WebSocket 1012: redial now).
    #[cfg(unix)]
    if listener_handover::handed_to_live() {
        unix_accept.abort();
        hub.restart_requested.store(true, std::sync::atomic::Ordering::SeqCst);
        tracing::info!("listeners handed over: stopped accepting; the next daemon serves them");
    }
    #[cfg(not(unix))]
    let _ = unix_accept;
    let shutdown_started = tokio::time::Instant::now();
    // First: the cmux link stops sending peers here before admission closes or the listener is
    // freed, so no process that binds the freed port can be taken for this daemon.
    drop(listener_record);
    // A home loss must request forced agent cleanup before the shutdown fence refuses changes
    // to the plan. A restart handoff keeps durable provider retries for the next daemon.
    recheck_home();
    let home_lost = crate::config::home_lost();
    if home_lost {
        let _ = hub.end_agents_at_shutdown(Default::default());
    }
    // Fence automatic continuations before any transport or metadata drain can yield to them.
    hub.begin_shutdown();
    // The plan is fixed now: a shutdown that ends its agents gets the time their ends take.
    let shutdown_deadline = shutdown_started + shutdown_budget(hub.ends_agents_at_shutdown());
    // Every bound below is a timer on this runtime. With `start` in `acpmux.v2` a thread ends the
    // process 800 ms in when the stop is held all the same (`daemon/stop_watchdog.rs`); with the
    // setting empty there is none. `run`'s return disarms it.
    let hard_exit = v2.as_ref().is_some_and(|v2| v2.allows_surfaces(&["start"]));
    let _hard_exit = stop_watchdog::arm(&hub, shutdown_deadline.into_std(), hard_exit);
    let shutdown_left = || shutdown_deadline.saturating_duration_since(tokio::time::Instant::now());
    // Session/transport cleanup cannot consume the writers' entire chance to drain.
    let cleanup_deadline = shutdown_deadline - Duration::from_millis(250);
    // Fence tailnet supervision first: its ingress then ends through the
    // WebSocket shutdown below (1012 on restart), never as a listener failure.
    // A supervisor action under way finishes first, within its own bounds.
    #[cfg(all(unix, feature = "tailnet"))]
    let _ = tokio::time::timeout_at(cleanup_deadline, tailnet.fence()).await;
    // Its home is gone (`daemon/home_watch.rs`): no later daemon can adopt its agents from
    // there, so they end; and this shutdown removes nothing at the old paths, which may be
    // another daemon's now (`config::mark_home_lost` refuses its writes there).
    startup.abort();
    let _ = tokio::time::timeout_at(cleanup_deadline, startup).await;
    // Its last heartbeat empties this daemon's rows in the hub's address book. The start's
    // join task ends first, so nothing starts a relay after this stops it.
    let _ = tokio::time::timeout_at(
        cleanup_deadline,
        crate::server::machine_enroll::stop_at_shutdown(&hub),
    )
    .await;
    // SIGTERM handoff and explicit updates/restarts use 1012. Explicit ordinary RPC
    // shutdown and interactive interrupt use a normal WebSocket close.
    let restarting = hub.restart_requested.load(std::sync::atomic::Ordering::SeqCst);
    if restarting {
        ws_shutdown.restart();
    } else {
        ws_shutdown.normal_shutdown();
    }
    let drain_deadline = std::cmp::min(
        cleanup_deadline,
        tokio::time::Instant::now() + crate::server::WS_DRAIN_BUDGET,
    );
    if tokio::time::timeout_at(drain_deadline, ws_shutdown.drained()).await.is_err() {
        tracing::warn!("websocket listeners did not drain before the shutdown deadline");
    }
    if let Some(mut task) = ws_task
        && tokio::time::timeout_at(drain_deadline, &mut task).await.is_err()
    {
        task.abort();
        let _ = tokio::time::timeout_at(cleanup_deadline, task).await;
        tracing::warn!("websocket clients did not drain before the shutdown deadline");
    }
    // The ingress has had the WebSocket drain to close its clients; stop and
    // join whatever remains within the service's own bound.
    #[cfg(all(unix, feature = "tailnet"))]
    let _ = tokio::time::timeout_at(cleanup_deadline, tailnet.shutdown()).await;
    // Keep encrypted bridges alive until WebSocket close/restart frames have drained.
    if let Some(transport) = wireguard {
        transport.shutdown(cleanup_deadline).await;
    }
    // A node a person started closes with the daemon; its saved login stays.
    // The controller is made here if no request made it (it holds no node
    // until a start), so a start racing this shutdown is refused either way.
    #[cfg(all(unix, feature = "tailnet"))]
    match tokio::time::timeout_at(cleanup_deadline, hub.tailnet_controller().shutdown()).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => tracing::warn!("embedded tailnet close: {error}"),
        Err(_) => tracing::warn!("embedded tailnet did not close within {SHUTDOWN_BUDGET:?}"),
    }
    hub.stop_idle_reaper();
    let cleanup_took = shutdown_started.elapsed();
    // New clients get "connection refused" instead of a dying daemon. Only the socket this
    // daemon bound: one replaced since is another daemon's.
    recheck_home();
    // One that could not be read right after the bind is left alone: it may be another's. (A
    // replacement between this check and the unlink cannot be ruled out: unlink takes a path.)
    // Off Unix there is no identity to read: the socket goes, as it always did.
    let bound_socket = bound_socket.into_inner().unwrap_or_else(PoisonError::into_inner);
    if bound_socket.as_ref().map_or(!cfg!(unix), |s| s.lost().is_none()) && !socket_handed() {
        // The home watch runs on through the shutdown: this removal is not a loss.
        home_watch::release_socket();
        let _ = crate::home_fs::remove_file(socket_path());
    }
    // How many hosted agents this shutdown kept running for the next
    // daemon; unknown (a timeout) counts as kept.
    let mut sessions = {
        let hub = hub.clone();
        exit_tasks.spawn_named("shutdown-sessions", async move {
            // A signal can arrive while metadata loads. Snapshot every stored session before
            // detaching or ending hosts. A timeout conservatively keeps their router below.
            let _ = metadata.await;
            if restarting {
                hub.shutdown_for_handoff(true).await
            } else {
                hub.shutdown_for_handoff(false).await
            }
        })
    };
    let mut unfinished_sessions = None;
    let sessions_started = tokio::time::Instant::now();
    let kept = match tokio::time::timeout_at(cleanup_deadline, &mut sessions).await {
        Ok(Ok(kept)) => kept,
        _ => {
            sessions.abort();
            unfinished_sessions = Some(sessions);
            tracing::warn!("agents did not stop within {SHUTDOWN_BUDGET:?}; exiting anyway");
            // Persistence still runs below, even when session cleanup used its whole grace.
            usize::MAX
        }
    };
    let sessions_took = sessions_started.elapsed();
    // A take-over that asked for them gets the connections that hold no state
    // (`server/conn_handover.rs`): their readers stop, what each already read is answered, and
    // their sockets go to the next daemon, where a request sent from now on is answered. Before
    // the drain, which refuses whatever a connection reads after it.
    #[cfg(unix)]
    if listener_handover::takes_connections() {
        let parked = crate::server::conn_handover::park();
        let moved = listener_handover::hand_connections(parked).await;
        tracing::info!(moved, "handed the connections that hold no state to the next daemon");
    }
    // The requests still in flight are answered as restarting before the close cancels their
    // connections, within a bound inside the deadline (`server/shutdown_drain.rs`).
    crate::server::shutdown_drain::drain_in_flight(&hub, cleanup_deadline).await;
    // The hub's own tasks after its agents: cancelled and joined, any left named (`hub/shutdown.rs`).
    hub.close_owned_tasks_until(cleanup_deadline).await;
    let persistence_started = tokio::time::Instant::now();
    let (cleanup_done, cleanup_finished) = tokio::sync::oneshot::channel::<()>();
    let mut persistence = {
        let hub = hub.clone();
        exit_tasks.spawn_named("shutdown-persistence", async move {
            // Abort is cooperative: a synchronous final session write may still be under way.
            // Never seal ahead of it or release ownership while it can still mutate the home.
            if let Some(sessions) = unfinished_sessions {
                let _ = sessions.await;
            }
            hub.persist_for_handoff(shutdown_deadline).await;
            // PID and token removal also belongs to this owner, before the next daemon may
            // acquire the lock and write its own files with the same names.
            let _ = cleanup_finished.await;
            // A timeout must not unlock the home while a blocking store fence still writes.
            // This task keeps both the lock and hub until persistence ends or the CLI exits.
            drop(_lock_file);
        })
    };
    // After the agents: their model streams go through the router.
    // A lost home's router path may be another daemon's router now: let go of ours, never ask
    // that path to stop.
    // Read after the agents: the home may have been lost while they drained.
    recheck_home();
    let home_lost = crate::config::home_lost();
    let _ = tokio::time::timeout(
        shutdown_left(),
        tokio::task::spawn_blocking(move || release_router(kept == 0 && !home_lost)),
    )
    .await;
    // Cancelled and finished before the removal, so a late retry never puts it back.
    if let Some(retry) = pid_retry {
        retry.abort();
        let _ = tokio::time::timeout_at(shutdown_deadline, retry).await;
    }
    recheck_home();
    if !crate::config::home_lost() {
        supervision::finish(&home(), exit_status());
        let _ = crate::home_fs::remove_file(home().join("daemon.pid"));
        for file in [local_app_file, peer_file, carrier_file].into_iter().flatten() {
            let _ = crate::home_fs::remove_file(file);
        }
    }
    // The carrier's registration last, as when the start held it to the end.
    crate::server::machine_enroll::stop_carrier(&hub);
    // Usage counts are written some time after they are made, so an idle
    // daemon never wakes for them; the last ones are written here.
    let _ = tokio::time::timeout(
        shutdown_left(),
        tokio::task::spawn_blocking(cmux_usage_patterns::flush),
    )
    .await;
    let _ = cleanup_done.send(());
    // The CLI exits the process once this returns, which would end a writer mid-write and lose
    // what it had yet to write (recent transcript, metadata, ledger and audit lines). So the
    // writers finish first, past the deadline too, with the home still locked (Codex review of
    // #42296). They hold no network or agent: on a healthy disk they end inside the deadline.
    if tokio::time::timeout_at(shutdown_deadline, &mut persistence).await.is_err() {
        tracing::warn!(
            "persistence still draining at the shutdown deadline; waiting for it with the home locked"
        );
        let _ = persistence.await;
    }
    // Where the handover's dark time went (the successor binds once the lock goes, right here).
    let took = shutdown_started.elapsed();
    let phases = format!(
        "shutdown took {} ms: cleanup {} ms, agents {} ms, persistence and release {} ms",
        took.as_millis(),
        cleanup_took.as_millis(),
        sessions_took.as_millis(),
        persistence_started.elapsed().as_millis(),
    );
    if took > shutdown_budget(hub.ends_agents_at_shutdown()) {
        tracing::warn!("{phases}");
    } else {
        tracing::info!("{phases}");
    }
    tracing::info!("stopped");
    Ok(())
}

// Covers every fallible startup step after bind, including token/config validation. Normal
// shutdown removes the socket explicitly; a replaced socket is never this guard's to remove.
struct BoundSocketCleanup(Option<home_watch::Owned>);

impl Drop for BoundSocketCleanup {
    fn drop(&mut self) {
        remove_bound_socket(self.0.as_ref());
    }
}

/// The socket file is the next daemon's: this one handed it the listener
/// (`daemon/listener_handover.rs`), so it stays.
fn socket_handed() -> bool {
    #[cfg(unix)]
    return listener_handover::handed_to_live();
    #[cfg(not(unix))]
    false
}

/// A startup that fails after the bind removes the socket only while it is still the one this
/// daemon bound: one replaced since is another daemon's. Off Unix there is no identity to read.
fn remove_bound_socket(bound: Option<&home_watch::Owned>) {
    if bound.map_or(!cfg!(unix), |s| s.lost().is_none()) && !socket_handed() {
        let _ = crate::home_fs::remove_file(socket_path());
    }
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
            crate::home_fs::set_permissions(path, std::fs::Permissions::from_mode(mode & 0o700))
    {
        tracing::warn!("could not make {} owner-only: {e}", path.display());
    }
}
/// Windows: replaces a wider access list with the owner-only one.
#[cfg(windows)]
use crate::owner_only::narrow as narrow_to_owner;

/// A detached daemon that remains alive but never binds its socket is a hung start.
/// This is the caller's fallback for that real hazard; lock-holder paths use
/// process/socket liveness instead of this bound.
// timeout: cleanup for a child that never reaches readiness must return to the CLI.
pub(crate) const START_BUDGET: Duration = Duration::from_secs(8);

/// Test-only upper bound used by integration assertions that dead-socket
/// failures remain prompt; production handover waits use peer liveness.
// timeout: test-only fast-failure assertion.
#[doc(hidden)]
pub const HANDOVER_BUDGET: Duration = Duration::from_secs(20);

/// How long a stopping daemon may take to exit: the agents' budget, the router's stop and kill
/// waits, and a margin.
pub const EXIT_BUDGET: Duration = SHUTDOWN_BUDGET
    .saturating_add(crate::hub::AGENT_END_BUDGET)
    .saturating_add(Duration::from_secs(8));

/// Wait until no daemon holds this home's lock (the running one exited),
/// at most [`EXIT_BUDGET`]. True when it was released.
pub async fn wait_for_exit() -> bool {
    // timeout: shutdown cleanup must return even if a crashed supervisor leaves
    // a lock held forever; ordinary client handover waits on lock liveness.
    wait_for_lock_release_with_budget(home().join("daemon.lock"), Some(EXIT_BUDGET)).await
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
fn spawn_detached(key: Option<zeroize::Zeroizing<String>>) -> Result<(std::fs::File, u32)> {
    let choice = start_exe::current(&home())?;
    let this = &choice.this;
    crate::config::private_state_dir(&home())?;
    let mut log = open_daemon_log(&home().join("daemon.log"))?;
    log_start_choice(&mut log, &choice);
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
    let mut cmd = daemon_command(this);
    crate::config::scrub_nested_claude_env(&mut cmd);
    // The daemon serves every session: its starter's turn values are not its own.
    for k in crate::config::inherited_caller_scoped_keys() {
        cmd.env_remove(k);
    }
    // Nor its starter's session marks: a daemon a chat's shell started carried that chat's id and
    // host nonce, and so did everything it started for other sessions, which made them read as
    // that chat's (`acpmux process owner`, `cli/process_owner.rs`).
    for k in STARTER_SESSION_MARKS {
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
    let child_pid = child.id().unwrap_or_default();
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
        // The daemon may be alive but busy before it can read its person key.
        // Keep that handoff off the caller's path and let EOF signal a dead
        // child instead of imposing a wall-clock cutoff.
        let _ = std::thread::Builder::new()
            .name("acpmux-person-key".into())
            .spawn(move || hand_key(ours, &key));
    }
    Ok((reader, child_pid))
}

/// Use the same home classification for initial launch and CLI restart.
pub(crate) fn uses_shared_home() -> bool {
    is_shared_home(&home())
}

/// Whether `home` is the shared daemon's home (`~/.acpmux`).
pub(crate) fn is_shared_home(home: &std::path::Path) -> bool {
    dirs::home_dir().map(|h| h.join(".acpmux")).as_deref() == Some(home)
}

/// v2's handle for `config`: none while `acpmux.v2` is empty. It holds a chat registry only when
/// the daemon writes books: `books` in the set and a store on disk (a store in memory makes no
/// registry and no books).
pub(crate) fn v2_handle(config: &Config) -> Option<std::sync::Arc<acpmux_core::life::V2>> {
    if config.acpmux_v2.is_empty() {
        return None;
    }
    let (hub, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
    let surfaces: std::collections::HashSet<String> =
        config.acpmux_v2.enabled().into_iter().map(str::to_owned).collect();
    let books = surfaces.contains("books") && config.store.mode != crate::config::StoreMode::Memory;
    let v2 = acpmux_core::life::V2::with_surfaces(hub, writer, surfaces);
    let v2 = if books { v2.with_registry(acpmux_core::registry::Registry::new()) } else { v2 };
    Some(std::sync::Arc::new(v2))
}

/// Whether a stop keeps this daemon's chats: agents under agent hosts (as the hub runs them,
/// never for a memory store, whatever `ACPMUX_AGENT_HOSTS` says), or chats on disk. The
/// app-orphan watch never stops a NIGHTLY or Release daemon without it.
fn keeps_chats_across_stop(hub: &Hub, memory_store: bool) -> bool {
    hub.agent_hosts_enabled() || !memory_store
}

#[cfg(test)]
mod keeps_chats_tests;
