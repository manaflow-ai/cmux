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

use std::future::Future;
use std::sync::{LazyLock, Weak};
use std::time::Duration;
use tokio::sync::watch;

use super::owner_exit;

/// How long a daemon goes unused before it stops.
pub(crate) const GRACE: Duration = Duration::from_secs(60 * 60);

/// This process's clients: how many are connected, and how many ever arrived.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Use {
    clients: usize,
    arrivals: u64,
}

static CLIENTS: LazyLock<watch::Sender<Use>> = LazyLock::new(|| watch::Sender::new(Use::default()));

/// One connected client, counted while it lives.
pub(crate) struct Client(&'static watch::Sender<Use>);

/// A client arrived; it is counted until the returned guard is dropped.
pub(crate) fn client() -> Client {
    arrive(&CLIENTS)
}

fn arrive(clients: &'static watch::Sender<Use>) -> Client {
    clients.send_modify(|u| {
        u.clients = u.clients.saturating_add(1);
        u.arrivals = u.arrivals.saturating_add(1);
    });
    Client(clients)
}

impl Drop for Client {
    fn drop(&mut self) {
        self.0.send_modify(|u| u.clients = u.clients.saturating_sub(1));
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
        // The guard `wait_for` returns is a lock: read from it and drop it before any await.
        let seen = clients.wait_for(|u| u.clients == 0).await.map(|u| u.arrivals);
        let Ok(seen) = seen else { return std::future::pending().await };
        let gone = *owner_gone.borrow_and_update();
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
        if now.clients > 0 || now.arrivals != seen {
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
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    const G: Duration = Duration::from_secs(60);

    fn sender() -> &'static watch::Sender<Use> {
        Box::leak(Box::new(watch::Sender::new(Use::default())))
    }

    fn nothing_keeps() -> impl FnMut() -> std::future::Ready<Option<&'static str>> {
        || std::future::ready(None)
    }

    fn no_owner() -> watch::Receiver<bool> {
        Box::leak(Box::new(watch::Sender::new(false))).subscribe()
    }

    fn owner() -> &'static watch::Sender<bool> {
        Box::leak(Box::new(watch::Sender::new(false)))
    }

    /// The owner app exits while no client is connected: the daemon stops one owner grace later,
    /// not one grace later.
    #[tokio::test(start_paused = true)]
    async fn quit_helpers_the_owners_exit_shortens_the_wait() {
        let (clients, app) = (sender(), owner());
        let task = tokio::spawn(unused_for(
            clients.subscribe(),
            Some(G),
            app.subscribe(),
            nothing_keeps(),
        ));
        tokio::time::sleep(G / 2).await;
        let quit = tokio::time::Instant::now();
        app.send_replace(true);
        let why = task.await.unwrap();
        assert!(why.starts_with(OWNER_GONE), "{why}");
        assert_eq!(quit.elapsed(), owner_exit::OWNER_EXIT_GRACE);
    }

    /// The shared home has no grace: only the owner's exit lets it stop.
    #[tokio::test(start_paused = true)]
    async fn quit_helpers_with_no_grace_only_the_owners_exit_stops_it() {
        let (clients, app) = (sender(), owner());
        let task =
            tokio::spawn(unused_for(clients.subscribe(), None, app.subscribe(), nothing_keeps()));
        tokio::time::sleep(G * 100).await;
        assert!(!task.is_finished(), "stopped with its app running");
        app.send_replace(true);
        let quit = tokio::time::Instant::now();
        task.await.unwrap();
        assert_eq!(quit.elapsed(), owner_exit::OWNER_EXIT_GRACE);
    }

    /// A client connected after the owner exited keeps the daemon; the short wait starts when it
    /// leaves.
    #[tokio::test(start_paused = true)]
    async fn quit_helpers_a_client_keeps_it_after_the_owners_exit() {
        let (clients, app) = (sender(), owner());
        app.send_replace(true);
        let held = arrive(clients);
        let task =
            tokio::spawn(unused_for(clients.subscribe(), None, app.subscribe(), nothing_keeps()));
        tokio::time::sleep(G * 10).await;
        assert!(!task.is_finished(), "stopped with a client");
        let left = tokio::time::Instant::now();
        drop(held);
        task.await.unwrap();
        assert_eq!(left.elapsed(), owner_exit::OWNER_EXIT_GRACE);
    }

    /// Work after the owner's exit (Keep Sessions Running): the daemon stays while it runs and
    /// asks again every recheck, then stops.
    #[tokio::test(start_paused = true)]
    async fn quit_helpers_work_keeps_it_after_the_owners_exit_and_is_asked_again() {
        let (clients, app) = (sender(), owner());
        app.send_replace(true);
        let asked = AtomicUsize::new(0);
        let in_use = || {
            let n = asked.fetch_add(1, Ordering::SeqCst);
            std::future::ready((n < 2).then_some("a running agent"))
        };
        let start = tokio::time::Instant::now();
        unused_for(clients.subscribe(), None, app.subscribe(), in_use).await;
        assert_eq!(asked.load(Ordering::SeqCst), 3);
        assert_eq!(
            start.elapsed(),
            owner_exit::OWNER_EXIT_GRACE + owner_exit::OWNER_KEPT_RECHECK * 2
        );
    }

    #[tokio::test(start_paused = true)]
    async fn no_client_for_the_grace_and_nothing_else_stops_it() {
        let clients = sender();
        let start = tokio::time::Instant::now();
        let why = unused_for(clients.subscribe(), Some(G), no_owner(), nothing_keeps()).await;
        assert!(why.starts_with("unused for 60s"), "{why}");
        assert_eq!(start.elapsed(), G);
    }

    #[tokio::test(start_paused = true)]
    async fn a_connected_client_keeps_it() {
        let clients = sender();
        let held = arrive(clients);
        let wait = unused_for(clients.subscribe(), Some(G), no_owner(), nothing_keeps());
        assert!(tokio::time::timeout(G * 10, wait).await.is_err(), "stopped with a client");
        drop(held);
    }

    #[tokio::test(start_paused = true)]
    async fn the_grace_starts_when_the_last_client_leaves() {
        let clients = sender();
        let held = arrive(clients);
        let task =
            tokio::spawn(unused_for(clients.subscribe(), Some(G), no_owner(), nothing_keeps()));
        tokio::time::sleep(G * 2).await;
        let left = tokio::time::Instant::now();
        drop(held);
        task.await.unwrap();
        assert_eq!(left.elapsed(), G);
    }

    /// A client that came and went inside a grace is seen, though the count is 0 again.
    #[tokio::test(start_paused = true)]
    async fn a_brief_visit_starts_the_grace_again() {
        let clients = sender();
        let start = tokio::time::Instant::now();
        let task =
            tokio::spawn(unused_for(clients.subscribe(), Some(G), no_owner(), nothing_keeps()));
        tokio::time::sleep(G / 2).await;
        drop(arrive(clients));
        task.await.unwrap();
        assert_eq!(start.elapsed(), G / 2 + G);
    }

    /// A client that arrived while the census ran keeps it, though nothing else did.
    #[tokio::test(start_paused = true)]
    async fn a_client_arriving_during_the_census_keeps_it() {
        let clients = sender();
        let asked = AtomicUsize::new(0);
        let start = tokio::time::Instant::now();
        let in_use = || {
            if asked.fetch_add(1, Ordering::SeqCst) == 0 {
                drop(arrive(clients));
            }
            std::future::ready(None)
        };
        unused_for(clients.subscribe(), Some(G), no_owner(), in_use).await;
        assert_eq!(asked.load(Ordering::SeqCst), 2);
        assert_eq!(start.elapsed(), G * 2);
    }

    #[tokio::test(start_paused = true)]
    async fn what_keeps_it_is_asked_again_one_grace_later() {
        let clients = sender();
        let asked = AtomicUsize::new(0);
        let start = tokio::time::Instant::now();
        let in_use = || {
            let n = asked.fetch_add(1, Ordering::SeqCst);
            std::future::ready((n < 2).then_some("a running agent"))
        };
        unused_for(clients.subscribe(), Some(G), no_owner(), in_use).await;
        assert_eq!(asked.load(Ordering::SeqCst), 3);
        assert_eq!(start.elapsed(), G * 3);
    }
}
