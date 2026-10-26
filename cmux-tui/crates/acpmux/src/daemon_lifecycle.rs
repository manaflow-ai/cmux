//! A leftover daemon exits (p07-memory-063, behind the default-off
//! `leftoverDaemonIdleExit` feature in `schemas/features/features.d`).
//!
//! Every cmux app, tagged dev build and CLI start leaves an acpmux daemon
//! running for good. With the feature on, the daemon exits once it has had,
//! for [`IDLE_EXIT_GRACE`], no client connection, no live agent (a harness or
//! agent host, a turn, a queued prompt, a pending permission, a start), no
//! running background process and no owning app. An app that restarts for an
//! update reconnects within the grace and keeps the daemon; any client that
//! connects and leaves starts the grace again.
//!
//! Chromium ends a renderer the same way once nothing refers to it
//! (`content/browser/renderer_host/render_process_host_impl.cc`,
//! `RenderProcessHostImpl::Cleanup` once its listener count and keep-alive
//! ref count reach zero) and its utility processes once their last client
//! disconnects; the delay matches the spare-renderer and Chromium host idle
//! exits in cmux.
//!
//! One task waits on the client presence channel and on the injected clock
//! for the grace deadline: it never polls. Agents, processes and the owning
//! app are read only at the deadline; when one still runs, a full grace
//! starts again (one wake per grace while a client-less daemon keeps agents).
//! The exit is fenced like the cmux-tui owner's (`stop_orphaned_owner`): the
//! presence closes only while no client connected since the deadline's read,
//! a closed presence refuses every new connection, and the live work is read
//! again under the fence; work found then opens the presence again.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch;

use crate::clock::Clock;

/// The registry name of the feature (`schemas/features/features.d`).
pub const FEATURE: &str = "leftoverDaemonIdleExit";

/// How long the daemon stays with nothing that needs it.
pub const IDLE_EXIT_GRACE: Duration = Duration::from_secs(10 * 60);

/// The process id of the app that owns this daemon; while that process runs
/// the daemon stays, connected or not.
pub const OWNER_APP_PID_ENV: &str = "ACPMUX_OWNER_APP_PID";

/// Connected clients, how many ever connected, and whether the daemon is
/// closing (no connection is taken any more).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Presence {
    clients: usize,
    arrivals: u64,
    closing: bool,
}

/// The daemon's client connections, counted by [`ClientGuard`]s.
#[derive(Debug)]
pub struct ClientPresence(Arc<watch::Sender<Presence>>);

impl Default for ClientPresence {
    fn default() -> Self {
        Self(Arc::new(watch::channel(Presence::default()).0))
    }
}

impl ClientPresence {
    /// A client connected; it counts until the guard drops. None once the
    /// daemon is closing: the connection is refused.
    pub fn connect(&self) -> Option<ClientGuard> {
        let mut taken = false;
        self.0.send_if_modified(|presence| {
            taken = !presence.closing;
            if taken {
                presence.clients += 1;
                presence.arrivals += 1;
            }
            taken
        });
        taken.then(|| ClientGuard(self.0.clone()))
    }

    /// Closes the presence when no client is connected and none arrived
    /// since `arrivals` was read; true when it closed.
    fn close_if_unchanged(&self, arrivals: u64) -> bool {
        let mut closed = false;
        self.0.send_if_modified(|presence| {
            closed = presence.clients == 0 && presence.arrivals == arrivals;
            presence.closing |= closed;
            closed
        });
        closed
    }

    /// Takes connections again after a close that found live work.
    fn reopen(&self) {
        self.0.send_if_modified(|presence| std::mem::replace(&mut presence.closing, false));
    }

    /// Connected clients now.
    pub fn clients(&self) -> usize {
        self.0.borrow().clients
    }

    fn subscribe(&self) -> watch::Receiver<Presence> {
        self.0.subscribe()
    }
}

/// One connected client; dropping it ends the connection's count.
#[derive(Debug)]
pub struct ClientGuard(Arc<watch::Sender<Presence>>);

impl Drop for ClientGuard {
    fn drop(&mut self) {
        self.0.send_modify(|presence| presence.clients = presence.clients.saturating_sub(1));
    }
}

/// What keeps a client-less daemon running, read only at a deadline.
pub trait Liveness: Send + Sync {
    /// Agents that run or are about to (see the module comment).
    fn live_agents(&self) -> usize;
    /// Background processes an agent started that still run.
    fn live_processes(&self) -> usize;
    /// The owning app's process runs.
    fn owner_app_alive(&self) -> bool;
}

fn keeps_daemon(liveness: &dyn Liveness) -> bool {
    liveness.live_agents() > 0 || liveness.live_processes() > 0 || liveness.owner_app_alive()
}

/// The next thing the waiter does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// A client is connected: wait for a presence change.
    Serve,
    /// Wait this long on the clock, or for a presence change.
    Wait(Duration),
    /// Exit the daemon.
    Exit,
}

/// The policy on the clock's time; the waiter feeds it.
#[derive(Debug)]
pub struct IdlePolicy {
    grace: Duration,
    /// When the daemon last became client-less; `None` while one is connected.
    idle_since: Option<Duration>,
}

impl IdlePolicy {
    pub fn new(grace: Duration) -> Self {
        Self { grace, idle_since: None }
    }

    /// The client count at `now`; `arrived` says a client connected since
    /// the last call (it may have left already), which starts the grace again.
    pub fn presence(&mut self, now: Duration, clients: usize, arrived: bool) {
        if clients > 0 {
            self.idle_since = None;
        } else if arrived || self.idle_since.is_none() {
            self.idle_since = Some(now);
        }
    }

    /// What to do at `now`. Past the grace, `keeps` is asked once: true
    /// starts a full grace again, false exits.
    pub fn step(&mut self, now: Duration, keeps: impl FnOnce() -> bool) -> Step {
        let Some(since) = self.idle_since else { return Step::Serve };
        let idle = now.saturating_sub(since);
        if idle < self.grace {
            return Step::Wait(self.grace - idle);
        }
        if keeps() {
            self.idle_since = Some(now);
            return Step::Wait(self.grace);
        }
        Step::Exit
    }

    /// An exit that did not happen (a client came, or work started, at the
    /// deadline): a full grace starts again at `now` while no client is connected.
    fn restart(&mut self, now: Duration) {
        if self.idle_since.is_some() {
            self.idle_since = Some(now);
        }
    }
}

/// Resolves when the daemon should exit; never while a client is connected.
/// On return the presence is closed: [`ClientPresence::connect`] refuses
/// every connection after it.
pub async fn wait_for_idle_exit(
    presence: &ClientPresence,
    clock: Arc<dyn Clock>,
    liveness: &dyn Liveness,
    grace: Duration,
) {
    let mut rx = presence.subscribe();
    let mut policy = IdlePolicy::new(grace);
    let mut last_arrivals = rx.borrow().arrivals;
    loop {
        let seen = *rx.borrow_and_update();
        policy.presence(clock.now(), seen.clients, seen.arrivals != last_arrivals);
        last_arrivals = seen.arrivals;
        let step = policy.step(clock.now(), || keeps_daemon(liveness));
        let changed = match step {
            Step::Exit => {
                // The fence: no client between the read above and the close,
                // and still nothing live once no client can start any.
                if presence.close_if_unchanged(last_arrivals) {
                    if !keeps_daemon(liveness) {
                        return;
                    }
                    presence.reopen();
                }
                policy.restart(clock.now());
                continue;
            }
            Step::Serve => rx.changed().await,
            Step::Wait(after) => {
                tokio::select! {
                    _ = clock.sleep_until(clock.now() + after) => Ok(()),
                    changed = rx.changed() => changed,
                }
            }
        };
        // The sender lives as long as `presence`: a closed channel means the
        // hub is going away, and the daemon's own shutdown ends it.
        if changed.is_err() {
            std::future::pending::<()>().await;
        }
    }
}

/// The owning app a launcher named in an environment variable (acpmux:
/// [`OWNER_APP_PID_ENV`]), read once at start.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OwnerApp {
    pid: Option<i32>,
}

impl OwnerApp {
    pub fn from_env(variable: &str) -> Self {
        Self::parse(std::env::var(variable).ok().as_deref())
    }

    /// A pid above 1; anything else names no owner.
    pub fn parse(value: Option<&str>) -> Self {
        let pid = value.and_then(|v| v.trim().parse::<i32>().ok()).filter(|pid| *pid > 1);
        Self { pid }
    }

    /// The owner's process exists (a recycled pid keeps the daemon: it fails
    /// toward staying).
    pub fn alive(&self) -> bool {
        let Some(pid) = self.pid else { return false };
        #[cfg(unix)]
        {
            // Signal 0 checks existence and permission only; EPERM means it exists.
            // SAFETY: kill with signal 0 delivers nothing and touches no memory.
            let rc = unsafe { libc::kill(pid, 0) };
            rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
        }
        #[cfg(not(unix))]
        {
            let _ = pid;
            true
        }
    }
}

/// The hub's facts for a daemon.
pub struct HubLiveness {
    pub hub: Arc<crate::hub::Hub>,
    pub owner: OwnerApp,
}

impl Liveness for HubLiveness {
    fn live_agents(&self) -> usize {
        self.hub.live_agent_count()
    }

    fn live_processes(&self) -> usize {
        self.hub.live_process_count()
    }

    fn owner_app_alive(&self) -> bool {
        self.owner.alive()
    }
}

/// Whether `features` turn the idle exit on.
fn enabled(features: &cmux_features::Snapshot) -> bool {
    features.is_enabled(cmux_features::feature::LEFTOVER_DAEMON_IDLE_EXIT)
}

/// The daemon's features, resolved as the cmux-tui owner resolves its own
/// (`cmux_features::sources`): the channel of the app bundle this daemon
/// ships in, the feature lists, then managed policy and the signed
/// document's `DisabledFeatures`, which win.
fn daemon_features() -> cmux_features::Snapshot {
    let exe = std::env::current_exe().ok();
    let kind = exe.as_deref().and_then(cmux_features::sources::bundle_kind);
    cmux_features::sources::daemon_snapshot(kind)
}

/// The daemon's idle exit when the feature is on (off on every channel by
/// default); resolves when the daemon should exit, never when it is off.
pub async fn run_for_daemon(hub: Arc<crate::hub::Hub>) {
    // The policy and document reads are disk reads: off the runtime's workers.
    let features = cmux_blocking::spawn_blocking(daemon_features).await;
    if !features.as_ref().is_ok_and(enabled) {
        return std::future::pending().await;
    }
    let clock = hub.lifecycle_clock();
    let liveness = HubLiveness { hub: hub.clone(), owner: OwnerApp::from_env(OWNER_APP_PID_ENV) };
    wait_for_idle_exit(&hub.clients, clock, &liveness, IDLE_EXIT_GRACE).await;
}

#[cfg(test)]
#[path = "daemon_lifecycle_tests.rs"]
mod idle_exit_tests;
