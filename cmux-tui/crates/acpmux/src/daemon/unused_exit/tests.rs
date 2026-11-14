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
    let task =
        tokio::spawn(unused_for(clients.subscribe(), Some(G), app.subscribe(), nothing_keeps()));
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
    assert_eq!(start.elapsed(), owner_exit::OWNER_EXIT_GRACE + owner_exit::OWNER_KEPT_RECHECK * 2);
}

/// R-LIFECYCLE ORPHANS: after a Keep Sessions quit with live shells, the app's cmux-tui
/// daemon stays (it holds the terminals) and keeps one `_acpmux/watch` open for its chat
/// notices. That watch only observes: once the owner app is gone it keeps nothing, so the
/// daemon and its router stop when no agent, turn or task keeps them (fleet repro on build
/// 3a43a131: acpmux and router ran on with parent 1 after every quit).
#[tokio::test(start_paused = true)]
async fn quit_helpers_a_watch_only_client_keeps_nothing_after_the_owners_exit() {
    let (clients, app) = (sender(), owner());
    let watcher = arrive(clients);
    watcher.observes();
    let task =
        tokio::spawn(unused_for(clients.subscribe(), None, app.subscribe(), nothing_keeps()));
    tokio::time::sleep(G * 10).await;
    assert!(!task.is_finished(), "stopped with its app running");
    app.send_replace(true);
    let quit = tokio::time::Instant::now();
    let why = task.await.unwrap();
    assert!(why.starts_with(OWNER_GONE), "{why}");
    assert_eq!(quit.elapsed(), owner_exit::OWNER_EXIT_GRACE);
    drop(watcher);
}

/// While the owner app runs, a watch-only client keeps the daemon as any client does.
#[tokio::test(start_paused = true)]
async fn a_watch_only_client_keeps_it_while_its_app_runs() {
    let clients = sender();
    let watcher = arrive(clients);
    watcher.observes();
    let wait = unused_for(clients.subscribe(), Some(G), owner().subscribe(), nothing_keeps());
    assert!(tokio::time::timeout(G * 10, wait).await.is_err(), "stopped with a client");
}

/// A client that also works (not only a watch) keeps it after the owner's exit.
#[tokio::test(start_paused = true)]
async fn quit_helpers_a_working_client_beside_a_watcher_keeps_it() {
    let (clients, app) = (sender(), owner());
    app.send_replace(true);
    let watcher = arrive(clients);
    watcher.observes();
    let worker = arrive(clients);
    let task =
        tokio::spawn(unused_for(clients.subscribe(), None, app.subscribe(), nothing_keeps()));
    tokio::time::sleep(G * 10).await;
    assert!(!task.is_finished(), "stopped with a working client");
    let left = tokio::time::Instant::now();
    drop(worker);
    task.await.unwrap();
    assert_eq!(left.elapsed(), owner_exit::OWNER_EXIT_GRACE);
    drop(watcher);
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
    let task = tokio::spawn(unused_for(clients.subscribe(), Some(G), no_owner(), nothing_keeps()));
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
    let task = tokio::spawn(unused_for(clients.subscribe(), Some(G), no_owner(), nothing_keeps()));
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
