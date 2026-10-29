//! The acpmux daemon's exit when nothing needs it: the stop rule every app
//! helper follows (`cmux-owner-liveness`; principled audit lagQuitHelpers,
//! 2026-10-29, which replaced cp/lag-quit-helpers' edge latch):
//!
//! > the daemon exits when it has no client connection, no live owner app
//! > and no live work (a live agent: a harness or agent host, a turn, a
//! > queued prompt, a pending permission, a start; or a running background
//! > process an agent started).
//!
//! The rule is recomputed from current truth at every change: a client
//! connects or leaves ([`ClientPresence`]), the live work changes or the
//! owner app exits ([`ClientPresence::work_changed`], which the owner's
//! kernel watch calls), and at each deadline. Nothing is latched: an owner
//! that exited during a Keep Sessions turn still counts as gone when that
//! turn ends.
//!
//! - Owning app (`ACPMUX_OWNER_APP_PID`, followed through one kernel handle,
//!   [`OwnerLiveness`]): while it runs it keeps the daemon. Once it is gone
//!   the daemon stops [`OWNER_EXIT_GRACE`] after the rule first says so (an
//!   app that restarts for an update reconnects within it). Chromium ends a
//!   child process when the browser process goes (`ChildProcessHost`
//!   channel error).
//! - No owning app (a daemon the CLI started): the default-off
//!   `leftoverDaemonIdleExit` feature (`schemas/features/features.d`)
//!   decides only whether that keeps the daemon. With it on, such a daemon
//!   stops [`IDLE_EXIT_GRACE`] after the rule first says so, as Chromium
//!   ends a renderer once nothing refers to it
//!   (`RenderProcessHostImpl::Cleanup`).
//!
//! The hub reports work changes (a session's status, a background process
//! that starts or ends, the end of startup, a pooled start). A change it
//! cannot report (a lock held by a short start) is read again every
//! [`IDLE_EXIT_GRACE`] while live work is the only thing that keeps a
//! client-less daemon.
//!
//! The exit is fenced like the cmux-tui owner's (`stop_orphaned_owner`): the
//! presence closes only while no client connected since the rule's read, a
//! closed presence refuses every new connection, and the live work and the
//! owner are read again under the fence; anything found then opens the
//! presence again.

use std::sync::{Arc, OnceLock};
use std::time::Duration;

use cmux_owner_liveness::{Keeps, OwnerApp, OwnerLiveness, OwnerState, Watch};
use cmux_tui_platform::process_priority::{PriorityError, ProcessPriority, SelfLowered};
use tokio::sync::watch;

use crate::clock::Clock;

pub use cmux_owner_liveness::OWNER_EXIT_GRACE;

/// The registry name of the feature (`schemas/features/features.d`).
pub const FEATURE: &str = "leftoverDaemonIdleExit";

/// How long a daemon no app named stays with nothing that needs it (with
/// the feature on), and how often unreported work changes are read again.
pub const IDLE_EXIT_GRACE: Duration = Duration::from_secs(10 * 60);

/// The process id of the app that owns this daemon; while that process runs
/// the daemon stays, connected or not.
pub const OWNER_APP_PID_ENV: &str = "ACPMUX_OWNER_APP_PID";

/// Connected clients, how many ever connected, whether the daemon is
/// closing (no connection is taken any more), and whether it runs
/// best-effort ([`ClientPresence::run_idle_priority`]).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Presence {
    clients: usize,
    arrivals: u64,
    closing: bool,
    background: bool,
    /// What the best-effort change lowered, for the change back.
    lowered: SelfLowered,
    /// Bumped by each [`ClientPresence::foreground`]: a best-effort change
    /// decided before one is not applied after it.
    starts: u64,
}

/// Sets this process's priority (`cmux_tui_platform::process_priority::set_self`).
pub type SelfPriority =
    Arc<dyn Fn(ProcessPriority, &mut SelfLowered) -> Result<(), PriorityError> + Send + Sync>;

/// The daemon's client connections, counted by [`ClientGuard`]s.
pub struct ClientPresence {
    presence: Arc<watch::Sender<Presence>>,
    /// Set with the `idleHelperBackgroundPriority` feature
    /// ([`ClientPresence::install_priority`]).
    priority: Arc<OnceLock<SelfPriority>>,
    /// Bumped when the daemon's live work or its owner app changed
    /// ([`ClientPresence::work_changed`]): `run_idle_priority`'s `quiet` and
    /// the exit rule ([`wait_for_daemon_exit`]) are asked again. A watch, so
    /// every waiter sees each change.
    work: Arc<watch::Sender<u64>>,
}

impl std::fmt::Debug for ClientPresence {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClientPresence").field("presence", &*self.presence.borrow()).finish()
    }
}

impl Default for ClientPresence {
    fn default() -> Self {
        Self {
            presence: Arc::new(watch::channel(Presence::default()).0),
            priority: Arc::default(),
            work: Arc::new(watch::channel(0).0),
        }
    }
}

/// Applies `priority` with `set` and records it in `presence`; a change the
/// kernel refused leaves the record as it was, so the next turn tries again.
fn change_priority(set: Option<&SelfPriority>, presence: &mut Presence, priority: ProcessPriority) {
    let Some(set) = set else { return };
    let background = priority == ProcessPriority::BestEffort;
    if presence.background == background {
        return;
    }
    match set(priority, &mut presence.lowered) {
        Ok(()) => presence.background = background,
        Err(e) => tracing::warn!("acpmux priority stays as it was ({priority:?}): {e}"),
    }
}

impl ClientPresence {
    /// A client connected; it counts until the guard drops. None once the
    /// daemon is closing: the connection is refused. A daemon that ran
    /// best-effort is back at its normal priority before it is served.
    pub fn connect(&self) -> Option<ClientGuard> {
        let mut taken = false;
        self.presence.send_if_modified(|presence| {
            taken = !presence.closing;
            if taken {
                change_priority(self.priority.get(), presence, ProcessPriority::UserVisible);
                presence.clients += 1;
                presence.arrivals += 1;
            }
            taken
        });
        taken.then(|| ClientGuard(self.presence.clone()))
    }

    /// Run idle phases best-effort with `set` (once per daemon; false when
    /// one was installed before).
    pub fn install_priority(&self, set: SelfPriority) -> bool {
        self.priority.set(set).is_ok()
    }

    /// The daemon at its normal priority, before it starts an agent or a
    /// pooled host: a process it starts inherits its priority. Call it once
    /// the start counts in `run_idle_priority`'s `quiet`: a best-effort
    /// change decided before this call is then not applied.
    pub fn foreground(&self) {
        self.presence.send_if_modified(|presence| {
            presence.starts += 1;
            change_priority(self.priority.get(), presence, ProcessPriority::UserVisible);
            false
        });
    }

    /// What `run_idle_priority`'s `quiet` or the exit rule reads changed (an
    /// agent or a turn ended, startup finished, a pooled start ended, the
    /// owner app exited or a newer one is followed): they are asked again.
    pub fn work_changed(&self) {
        self.work.send_modify(|changes| *changes = changes.wrapping_add(1));
    }

    /// Whether the daemon runs best-effort now.
    pub fn background(&self) -> bool {
        self.presence.borrow().background
    }

    /// Runs the daemon best-effort while no client is connected and `quiet`
    /// (no agent runs, no pooled start is under way), and at its normal
    /// priority again when work runs without a client, as Chromium runs a
    /// renderer nobody shows (`RenderProcessHostImpl::UpdateProcessPriority`).
    /// `quiet` is asked when the presence changes and on each
    /// [`ClientPresence::work_changed`]. A connection
    /// ([`ClientPresence::connect`]) or a start
    /// ([`ClientPresence::foreground`]) puts it back in its own turn. Does
    /// nothing until [`ClientPresence::install_priority`].
    pub fn run_idle_priority(
        &self,
        quiet: impl Fn() -> bool + Send + 'static,
    ) -> impl std::future::Future<Output = ()> + Send + 'static {
        let sender = self.presence.clone();
        let priority = self.priority.clone();
        let mut work = self.work.subscribe();
        let mut presence = sender.subscribe();
        async move {
            loop {
                let (clients, closing, arrivals, starts) = {
                    let seen = presence.borrow_and_update();
                    (seen.clients, seen.closing, seen.arrivals, seen.starts)
                };
                let mut again = false;
                if priority.get().is_some() && clients == 0 && !closing {
                    let wanted = if quiet() {
                        ProcessPriority::BestEffort
                    } else {
                        ProcessPriority::UserVisible
                    };
                    // Fenced as the idle exit is: only when no client arrived
                    // and nothing started since `quiet` was read.
                    sender.send_if_modified(|now| {
                        let unchanged = now.clients == 0
                            && now.arrivals == arrivals
                            && now.starts == starts
                            && !now.closing;
                        if unchanged {
                            change_priority(priority.get(), now, wanted);
                        } else {
                            // A start raced the read: read again.
                            again = now.clients == 0 && now.arrivals == arrivals;
                        }
                        false
                    });
                }
                if again {
                    continue;
                }
                tokio::select! {
                    changed = presence.changed() => if changed.is_err() { return },
                    changed = work.changed() => if changed.is_err() { return },
                }
            }
        }
    }

    /// Closes the presence when no client is connected and none arrived
    /// since `arrivals` was read; true when it closed.
    fn close_if_unchanged(&self, arrivals: u64) -> bool {
        let mut closed = false;
        self.presence.send_if_modified(|presence| {
            closed = presence.clients == 0 && presence.arrivals == arrivals;
            presence.closing |= closed;
            closed
        });
        closed
    }

    /// Takes connections again after a close that found live work.
    fn reopen(&self) {
        self.presence.send_if_modified(|presence| std::mem::replace(&mut presence.closing, false));
    }

    /// Connected clients now.
    pub fn clients(&self) -> usize {
        self.presence.borrow().clients
    }

    fn subscribe(&self) -> watch::Receiver<Presence> {
        self.presence.subscribe()
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

/// What keeps a client-less daemon running, read at every change.
pub trait Liveness: Send + Sync {
    /// Agents that run or are about to (see the module comment).
    fn live_agents(&self) -> usize;
    /// Background processes an agent started that still run.
    fn live_processes(&self) -> usize;
    /// The owning app, as a level.
    fn owner(&self) -> OwnerState;
    /// Whether a change of [`Liveness::owner`] is reported
    /// ([`ClientPresence::work_changed`]); else the daemon reads it again
    /// every [`IDLE_EXIT_GRACE`] while it keeps the daemon.
    fn owner_reports_changes(&self) -> bool {
        true
    }
}

fn live_work(liveness: &dyn Liveness) -> bool {
    liveness.live_agents() > 0 || liveness.live_processes() > 0
}

/// How long the rule must hold before the daemon stops: an owner that is
/// gone gives [`OWNER_EXIT_GRACE`], a daemon no app named [`IDLE_EXIT_GRACE`].
fn grace(owner: OwnerState) -> Duration {
    match owner {
        OwnerState::Gone => OWNER_EXIT_GRACE,
        OwnerState::Unnamed | OwnerState::Alive => IDLE_EXIT_GRACE,
    }
}

/// Resolves when the daemon should exit: once the stop rule
/// ([`Keeps::exits`]) has held for its grace; never while a client is
/// connected. `unowned_keeps`: a daemon no app named stays for good
/// (`leftoverDaemonIdleExit` off). On return the presence is closed:
/// [`ClientPresence::connect`] refuses every connection after it.
pub async fn wait_for_daemon_exit(
    presence: &ClientPresence,
    clock: Arc<dyn Clock>,
    liveness: &dyn Liveness,
    unowned_keeps: bool,
) {
    let mut rx = presence.subscribe();
    let mut work = presence.work.subscribe();
    let mut last_arrivals = rx.borrow().arrivals;
    // When the rule last started to say "exit"; None while it says "stay".
    let mut since: Option<Duration> = None;
    // A close found something that keeps the daemon: the grace starts again.
    let mut reopened = false;
    loop {
        let seen = rx.borrow_and_update().clone();
        work.mark_unchanged();
        let arrived = std::mem::take(&mut reopened) || seen.arrivals != last_arrivals;
        last_arrivals = seen.arrivals;
        // A connected client decides alone: the work and the owner are not read.
        let clients = seen.clients > 0;
        let keeps = Keeps {
            clients,
            owner: if clients { OwnerState::Alive } else { liveness.owner() },
            live_work: !clients && live_work(liveness),
        };
        let now = clock.now();
        since = match since {
            _ if !keeps.exits(unowned_keeps) => None,
            // A client that came and went (or work found under the fence)
            // starts the grace again.
            Some(at) if !arrived => Some(at),
            _ => Some(now),
        };
        let wake = match since {
            Some(at) if now >= at + grace(keeps.owner) => {
                // The fence: no client between the read above and the close,
                // and still nothing that keeps it once no client can start work.
                if presence.close_if_unchanged(last_arrivals) {
                    let fenced = Keeps {
                        clients: false,
                        owner: liveness.owner(),
                        live_work: live_work(liveness),
                    };
                    if fenced.exits(unowned_keeps) {
                        // The clients and the owner read again after the close:
                        // no client can come now, and an owner that is gone or
                        // unnamed cannot come back (this daemon follows no pid
                        // file). The work is the fenced read's: a request a
                        // client left running may still start work, and a
                        // second read here would race it (known fence gap).
                        let now_keeps = Keeps {
                            clients: presence.clients() > 0,
                            owner: liveness.owner(),
                            ..fenced
                        };
                        cmux_owner_liveness::check("acpmux", true, now_keeps, unowned_keeps);
                        return;
                    }
                    presence.reopen();
                }
                reopened = true;
                continue;
            }
            Some(at) => Some(at + grace(keeps.owner)),
            None => {
                // Live work alone keeps a client-less daemon: work changes the
                // hub does not report are read again after a grace. So is an
                // owner whose changes are not reported (no follow thread).
                let only_work = Keeps { live_work: false, ..keeps }.exits(unowned_keeps);
                let unreported_owner = !keeps.clients
                    && keeps.owner == OwnerState::Alive
                    && !liveness.owner_reports_changes();
                ((keeps.live_work && only_work) || unreported_owner).then(|| now + IDLE_EXIT_GRACE)
            }
        };
        let changed = match wake {
            Some(at) => tokio::select! {
                () = clock.sleep_until(at) => Ok(()),
                changed = rx.changed() => changed,
                changed = work.changed() => changed,
            },
            None => tokio::select! {
                changed = rx.changed() => changed,
                changed = work.changed() => changed,
            },
        };
        // The senders live as long as `presence`: a closed channel means the
        // hub is going away, and the daemon's own shutdown ends it.
        if changed.is_err() {
            std::future::pending::<()>().await;
        }
    }
}

/// The hub's facts for a daemon.
pub struct HubLiveness {
    pub hub: Arc<crate::hub::Hub>,
    pub owner: Arc<OwnerLiveness>,
}

impl Liveness for HubLiveness {
    fn live_agents(&self) -> usize {
        self.hub.live_agent_count()
    }

    fn live_processes(&self) -> usize {
        self.hub.live_process_count()
    }

    fn owner(&self) -> OwnerState {
        self.owner.state()
    }

    fn owner_reports_changes(&self) -> bool {
        self.owner.reports_changes()
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
pub(crate) fn daemon_features() -> cmux_features::Snapshot {
    let exe = std::env::current_exe().ok();
    let kind = exe.as_deref().and_then(cmux_features::sources::bundle_kind);
    cmux_features::sources::daemon_snapshot(kind)
}

/// The daemon's exit when nothing needs it (see [`wait_for_daemon_exit`]).
pub async fn run_for_daemon(hub: Arc<crate::hub::Hub>) {
    // The policy and document reads are disk reads: off the runtime's workers.
    let features = cmux_blocking::spawn_blocking(daemon_features).await;
    let unowned_keeps = !features.as_ref().is_ok_and(enabled);
    let clock = hub.lifecycle_clock();
    // The owner app's changes reach the rule as work changes; installed
    // before the follow, so no change is missed.
    let owner = OwnerLiveness::new(None);
    let weak = Arc::downgrade(&hub);
    owner.observe(move || {
        if let Some(hub) = weak.upgrade() {
            hub.clients.work_changed();
        }
    });
    match owner.follow(OwnerApp::from_env(OWNER_APP_PID_ENV)) {
        Watch::Polled(error) => {
            tracing::warn!("the owning app is checked every second (no kernel handle: {error})");
        }
        Watch::Unwatched(error) => {
            tracing::warn!("the owning app's exit is read only at the next change ({error})");
        }
        Watch::Unnamed | Watch::Kernel | Watch::Gone => {}
    }
    let liveness = HubLiveness { hub: hub.clone(), owner };
    // Startup work counts as live until it is done: the rule reads it again then.
    let started = Arc::downgrade(&hub);
    let startup = async move {
        if let Some(hub) = started.upgrade() {
            hub.wait_startup().await;
            hub.wait_logs().await;
            hub.clients.work_changed();
        }
        std::future::pending::<()>().await;
    };
    tokio::select! {
        () = wait_for_daemon_exit(&hub.clients, clock, &liveness, unowned_keeps) => {}
        () = startup => {}
    }
}

#[cfg(test)]
#[path = "daemon_lifecycle_tests.rs"]
mod idle_exit_tests;

#[path = "daemon_idle_priority.rs"]
pub(crate) mod idle_priority;

#[cfg(test)]
#[path = "daemon_priority_tests.rs"]
mod idle_priority_tests;
