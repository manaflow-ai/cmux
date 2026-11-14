//! A daemon nobody uses stops. Leo's Mac, 2026-10-30: daemons of tagged builds and of
//! temporary homes ran for days beside the app's own, each with nothing attached, while the Mac
//! sat at load 150-230 and swapped ("JUST FUCKING REMOVE THE FUCKING OLD DAMEMONS"). A daemon
//! whose home, socket or lock is gone already stops (`home_watch.rs`); this is the one whose
//! home still exists but that no app, command or agent uses any more.
//!
//! The rule: a daemon on a home of its own (any home but the shared `~/.acpmux`, which NIGHTLY, the
//! CLI and every peer expect to answer), not run by acpmux's own service unit and not on a Cloud
//! machine (whose hand-off reports wait in its memory, `cloud_handoff.rs`) stops normally once it
//! has had no client for [`GRACE`] and, at the end of it, nothing else keeps it
//! ([`crate::hub::Hub::in_use`]): its startup and adoption done, no running agent or agent host
//! (adopted or not), no turn or anything one waits on, no background task, no undelivered message
//! or watch, no peer link, and no listener another machine reaches it by (the mesh relay,
//! WireGuard, the tailnet, a WebSocket listener off loopback); and no client arrived meanwhile. The
//! stop is the one `_acpmux/shutdown` makes, not a restart handoff; with no agent there is none to
//! keep. An app or command that wants it again starts it again, as after any stop.
//!
//! A client is any authenticated connection the daemon serves (`server::serve_connection_from`):
//! the app's watch and panes, a command, an agent's MCP bridge, an in-process relay. Every
//! arrival counts, so one that came and went within a grace starts the grace again.
//!
//! No polling: the task waits for the last client to leave, then for [`GRACE`] or the next
//! arrival. While something else keeps the daemon it checks again one grace later; an idle daemon
//! with a client connected never wakes. `ACPMUX_UNUSED_EXIT_SECS` sets the grace (0: no grace, so
//! only the owner rule below can stop the daemon).
//!
//! A daemon whose owner app exited (`owner_exit.rs`: the app named itself in
//! `ACPMUX_OWNER_APP_PID`) follows the same rule on any home, the shared one too, with
//! [`owner_exit::OWNER_EXIT_GRACE`] instead of the grace, and while something keeps it asks again
//! every [`owner_exit::OWNER_KEPT_RECHECK`]. While the app runs, nothing changes.
//!
//! After the owner app exited, a client that only observes keeps nothing (R-LIFECYCLE ORPHANS):
//! one that said `_meta.acpmux.observer: true` in its `initialize` ([`Presence::observes`]). The
//! app's cmux-tui daemon stays after a Keep Sessions quit with live shells (it holds them) and
//! keeps its chat notices watch open; counted as a client, that watch kept the daemon and its
//! router running with parent 1 after every such quit (fleet repro on build 3a43a131). What
//! keeps an observed daemon is still asked ([`crate::hub::Hub::in_use`]): a running agent, a
//! turn, a pending permission, a background task, an agent host.

use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Weak};
use std::time::Duration;
use tokio::sync::watch;

use super::owner_exit;

/// How long a daemon goes unused before it stops.
pub(crate) const GRACE: Duration = Duration::from_secs(60 * 60);

/// This process's clients: how many are connected, how many of those only observe, and how many
/// ever arrived.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Use {
    clients: usize,
    observers: usize,
    arrivals: u64,
}

impl Use {
    /// The clients that keep the daemon: all of them while the owner app runs (`owner_gone`
    /// false), only those that do not merely observe once it exited.
    fn keeping(&self, owner_gone: bool) -> usize {
        if owner_gone { self.clients.saturating_sub(self.observers) } else { self.clients }
    }
}

static CLIENTS: LazyLock<watch::Sender<Use>> = LazyLock::new(|| watch::Sender::new(Use::default()));

/// One connected client, counted while it lives.
pub(crate) struct Client {
    clients: &'static watch::Sender<Use>,
    state: std::sync::Arc<ClientState>,
}

/// Changed only inside `send_modify`, so a client's observer mark and its departure are one
/// order with the counts.
#[derive(Default)]
struct ClientState {
    observer: AtomicBool,
    left: AtomicBool,
}

/// A handle a connection keeps to mark its client an observer, without holding the client.
#[derive(Clone)]
pub(crate) struct Presence {
    clients: &'static watch::Sender<Use>,
    state: std::sync::Weak<ClientState>,
}

/// A client arrived; it is counted until the returned guard is dropped.
pub(crate) fn client() -> Client {
    arrive(&CLIENTS)
}

fn arrive(clients: &'static watch::Sender<Use>) -> Client {
    clients.send_modify(|u| {
        u.clients = u.clients.saturating_add(1);
        u.arrivals = u.arrivals.saturating_add(1);
    });
    Client { clients, state: Default::default() }
}

impl Client {
    /// The handle a connection marks this client with ([`Presence::observes`]).
    pub(crate) fn presence(&self) -> Presence {
        Presence { clients: self.clients, state: std::sync::Arc::downgrade(&self.state) }
    }

    /// This client only observes: once the owner app exited it keeps nothing.
    #[cfg(test)]
    pub(crate) fn observes(&self) {
        self.presence().observes();
    }
}

impl Presence {
    /// Marks the client an observer (`initialize` with `_meta.acpmux.observer: true`), once; a
    /// client that already left is not counted again.
    pub(crate) fn observes(&self) {
        let Some(state) = self.state.upgrade() else { return };
        self.clients.send_modify(|u| {
            if !state.left.load(Ordering::Relaxed) && !state.observer.swap(true, Ordering::Relaxed)
            {
                u.observers = u.observers.saturating_add(1);
            }
        });
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let state = &self.state;
        self.clients.send_modify(|u| {
            state.left.store(true, Ordering::Relaxed);
            u.clients = u.clients.saturating_sub(1);
            if state.observer.load(Ordering::Relaxed) {
                u.observers = u.observers.saturating_sub(1);
            }
        });
    }
}

/// The grace `ACPMUX_UNUSED_EXIT_SECS` gives, else [`GRACE`]; None when it is 0.
fn grace() -> Option<Duration> {
    match std::env::var("ACPMUX_UNUSED_EXIT_SECS").ok().and_then(|v| v.trim().parse::<u64>().ok()) {
        Some(0) => None,
        Some(secs) => Some(Duration::from_secs(secs)),
        None => Some(GRACE),
    }
}

/// Resolves, with why, once this daemon is unused (see the module doc). Never for a daemon its
/// service unit runs or while a Cloud machine's reports wait; for the shared home or a grace of 0,
/// only after its owner app exited.
pub(super) async fn unused(hub: Weak<crate::hub::Hub>) -> String {
    if super::managed_by_acpmux_unit() {
        return std::future::pending().await;
    }
    let own_home = !super::uses_shared_home();
    let grace = grace().filter(|_| own_home);
    let owner = owner_exit::follow();
    if grace.is_none() && owner.is_none() {
        return std::future::pending().await;
    }
    let in_use = move || {
        let hub = hub.upgrade();
        async move {
            // A Cloud machine's hand-off reports wait in this daemon's memory
            // (`cloud_handoff.rs`). Read at each census: the Cloud agent may make its socket
            // after the daemon started.
            #[cfg(unix)]
            if super::cloud_handoff::reports_here() {
                return Some("a Cloud machine's hand-off reports");
            }
            match hub {
                Some(hub) => hub.in_use().await,
                // The hub is gone: the daemon is stopping anyway.
                None => Some("the daemon is stopping"),
            }
        }
    };
    let (owner_pid, owner_gone) = match owner {
        Some((pid, gone)) => (Some(pid), gone),
        // No owner: a sender that never sends and is never dropped.
        None => (None, NO_OWNER.subscribe()),
    };
    let why = unused_for(CLIENTS.subscribe(), grace, owner_gone, in_use).await;
    match owner_pid {
        Some(pid) if why.starts_with(OWNER_GONE) => format!("{why} (app pid {pid})"),
        _ => why,
    }
}

/// The owner receiver of a daemon with no owner app: never turns true.
static NO_OWNER: LazyLock<watch::Sender<bool>> = LazyLock::new(|| watch::Sender::new(false));

/// How a stop after the owner app's exit starts its reason.
const OWNER_GONE: &str = "its app quit";

/// Waits for `grace` (None: no limit) with no client, then asks `in_use` what keeps the daemon;
/// resolves when nothing does, else waits again. Once `owner_gone` is true (the owner app exited)
/// the wait is [`owner_exit::OWNER_EXIT_GRACE`], and after a census that found the daemon kept,
/// [`owner_exit::OWNER_KEPT_RECHECK`] (or the grace, when shorter).
async fn unused_for<F, Fut>(
    mut clients: watch::Receiver<Use>,
    grace: Option<Duration>,
    mut owner_gone: watch::Receiver<bool>,
    mut in_use: F,
) -> String
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Option<&'static str>>,
{
    let mut kept_after_owner = false;
    loop {
        let gone = *owner_gone.borrow_and_update();
        // The guard `wait_for` returns is a lock: read from it and drop it before any await.
        // The owner's exit while a client is connected may leave only observers: look again.
        let owner_exits = async {
            if gone || owner_gone.changed().await.is_err() {
                std::future::pending::<()>().await;
            }
        };
        let seen = tokio::select! {
            seen = clients.wait_for(|u| u.keeping(gone) == 0) => seen.map(|u| u.arrivals),
            _ = owner_exits => continue,
        };
        let Ok(seen) = seen else { return std::future::pending().await };
        let wait = if gone {
            let short = if kept_after_owner {
                owner_exit::OWNER_KEPT_RECHECK
            } else {
                owner_exit::OWNER_EXIT_GRACE
            };
            Some(grace.map_or(short, |g| g.min(short)))
        } else {
            grace
        };
        let sleep = async {
            match wait {
                Some(wait) => tokio::time::sleep(wait).await,
                None => std::future::pending().await,
            }
        };
        // A closed owner channel (its watch ended) is no exit: it is not waited on again.
        let owner_changed = async {
            if gone || owner_gone.changed().await.is_err() {
                std::future::pending::<()>().await;
            }
        };
        let woke = tokio::select! {
            _ = sleep => None,
            _ = clients.wait_for(|u| u.arrivals != seen) => Some(()),
            // The owner app exited during the wait: the short wait starts now.
            _ = owner_changed => Some(()),
        };
        if woke.is_some() {
            // A client came, or the owner just exited: the next wait is the short one again.
            kept_after_owner = false;
            continue;
        }
        let Some(waited) = wait else { continue };
        let kept = in_use().await;
        // A client that arrived while the census ran (or as the grace ended) keeps it.
        let now = *clients.borrow();
        if now.keeping(gone) > 0 || now.arrivals != seen {
            continue;
        }
        match kept {
            None if gone => {
                return format!(
                    "{OWNER_GONE} and nothing used the daemon for {}s: no client, agent, turn or task",
                    waited.as_secs()
                );
            }
            None => {
                return format!("unused for {}s: no client, agent, turn or task", waited.as_secs());
            }
            Some(why) => {
                kept_after_owner = gone;
                tracing::debug!("no client for {}s, kept by {why}", waited.as_secs());
            }
        }
    }
}

#[cfg(test)]
mod tests;
