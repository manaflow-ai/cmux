//! The leftover daemon idle exit on a fake clock (`cargo test -p acpmux idle_exit`).

use super::*;
use crate::clock::ManualClock;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

const GRACE: Duration = IDLE_EXIT_GRACE;

#[derive(Default)]
struct Facts {
    agents: AtomicUsize,
    processes: AtomicUsize,
    owner: AtomicBool,
}

impl Liveness for Facts {
    fn live_agents(&self) -> usize {
        self.agents.load(Ordering::SeqCst)
    }

    fn live_processes(&self) -> usize {
        self.processes.load(Ordering::SeqCst)
    }

    fn owner_app_alive(&self) -> bool {
        self.owner.load(Ordering::SeqCst)
    }
}

struct Run {
    clock: Arc<ManualClock>,
    presence: Arc<ClientPresence>,
    facts: Arc<Facts>,
    owner_exit: std::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    exit: tokio::task::JoinHandle<()>,
}

impl Run {
    fn start(facts: Facts) -> Self {
        let clock = ManualClock::new();
        let presence = Arc::new(ClientPresence::default());
        let facts = Arc::new(facts);
        let (owner_exit, exited) = tokio::sync::oneshot::channel::<()>();
        let exit = {
            let (clock, presence, facts) = (clock.clone(), presence.clone(), facts.clone());
            tokio::spawn(async move {
                // A dropped sender is no exit (the test ended without one).
                let owner = async move {
                    if exited.await.is_err() {
                        std::future::pending::<()>().await;
                    }
                };
                wait_for_idle_exit(&presence, clock, facts.as_ref(), GRACE, owner).await;
            })
        };
        Self { clock, presence, facts, owner_exit: std::sync::Mutex::new(Some(owner_exit)), exit }
    }

    /// The owning app's process exits (the facts say so, then the watch fires).
    async fn owner_exits(&self) {
        self.facts.owner.store(false, Ordering::SeqCst);
        let sender = self.owner_exit.lock().unwrap().take().expect("one owner exit per run");
        // A waiter that no longer watches has dropped the receiver; the asserts say what that did.
        let _ = sender.send(());
        settle().await;
    }

    /// Lets the waiter see every change so far, then moves the clock.
    async fn advance(&self, by: Duration) {
        settle().await;
        self.clock.advance(by);
        settle().await;
    }

    fn exited(&self) -> bool {
        self.exit.is_finished()
    }
}

async fn settle() {
    for _ in 0..16 {
        tokio::task::yield_now().await;
    }
}

#[tokio::test]
async fn idle_exit_after_the_grace_with_nothing_live() {
    let run = Run::start(Facts::default());
    run.advance(GRACE - Duration::from_secs(1)).await;
    assert!(!run.exited(), "exited before the grace");
    run.advance(Duration::from_secs(1)).await;
    assert!(run.exited(), "stayed past the grace with nothing live");
}

#[tokio::test]
async fn idle_exit_never_with_a_client() {
    let run = Run::start(Facts::default());
    let client = run.presence.connect().expect("an open daemon takes a client");
    run.advance(GRACE * 3).await;
    assert!(!run.exited(), "exited with a client connected");
    drop(client);
    run.advance(GRACE - Duration::from_secs(1)).await;
    assert!(!run.exited(), "the grace starts when the last client leaves");
    run.advance(Duration::from_secs(1)).await;
    assert!(run.exited());
}

#[tokio::test]
async fn idle_exit_grace_restarts_when_a_client_comes_and_goes() {
    // An app update: the old app leaves, the new one connects and leaves again.
    let run = Run::start(Facts::default());
    run.advance(GRACE - Duration::from_secs(5)).await;
    drop(run.presence.connect().expect("an open daemon takes a client"));
    run.advance(GRACE - Duration::from_secs(5)).await;
    assert!(!run.exited(), "a reconnect within the grace keeps the daemon");
    run.advance(Duration::from_secs(5)).await;
    assert!(run.exited());
}

#[tokio::test]
async fn idle_exit_stays_with_a_live_agent() {
    let run = Run::start(Facts { agents: AtomicUsize::new(1), ..Facts::default() });
    run.advance(GRACE * 3).await;
    assert!(!run.exited(), "exited with a live agent");
    run.facts.agents.store(0, Ordering::SeqCst);
    // The next look is one grace after the last one.
    run.advance(GRACE).await;
    assert!(run.exited());
}

#[tokio::test]
async fn idle_exit_stays_with_a_live_process() {
    let run = Run::start(Facts { processes: AtomicUsize::new(2), ..Facts::default() });
    run.advance(GRACE * 3).await;
    assert!(!run.exited(), "exited with a background process running");
}

#[tokio::test]
async fn idle_exit_stays_while_the_owning_app_runs() {
    let run = Run::start(Facts { owner: AtomicBool::new(true), ..Facts::default() });
    run.advance(GRACE * 3).await;
    assert!(!run.exited(), "exited while its app runs");
    run.facts.owner.store(false, Ordering::SeqCst);
    run.advance(GRACE).await;
    assert!(run.exited());
}

#[tokio::test]
async fn idle_exit_closes_to_new_clients() {
    let run = Run::start(Facts::default());
    run.advance(GRACE).await;
    assert!(run.exited());
    assert!(run.presence.connect().is_none(), "a client connected to an exiting daemon");
}

/// A client that connects between the deadline's read and the close (the
/// read sees no client; the client is there before the fence).
struct ArrivesAtTheDeadline {
    presence: Arc<ClientPresence>,
    armed: AtomicBool,
    client: std::sync::Mutex<Option<ClientGuard>>,
}

impl Liveness for ArrivesAtTheDeadline {
    fn live_agents(&self) -> usize {
        if self.armed.swap(false, Ordering::SeqCst) {
            *self.client.lock().unwrap() = self.presence.connect();
        }
        0
    }

    fn live_processes(&self) -> usize {
        0
    }

    fn owner_app_alive(&self) -> bool {
        false
    }
}

#[tokio::test]
async fn idle_exit_a_client_at_the_deadline_keeps_the_daemon() {
    let clock = ManualClock::new();
    let presence = Arc::new(ClientPresence::default());
    let liveness = Arc::new(ArrivesAtTheDeadline {
        presence: presence.clone(),
        armed: AtomicBool::new(true),
        client: Default::default(),
    });
    let exit = {
        let (clock, presence, liveness) = (clock.clone(), presence.clone(), liveness.clone());
        tokio::spawn(async move {
            wait_for_idle_exit(&presence, clock, liveness.as_ref(), GRACE, std::future::pending())
                .await;
        })
    };
    settle().await;
    clock.advance(GRACE);
    settle().await;
    assert!(!exit.is_finished(), "exited with a client that connected at the deadline");
    assert_eq!(presence.clients(), 1, "the client was refused");
    clock.advance(GRACE * 3);
    settle().await;
    assert!(!exit.is_finished(), "exited while that client stays");
    drop(liveness.client.lock().unwrap().take());
    settle().await;
    clock.advance(GRACE);
    settle().await;
    assert!(exit.is_finished(), "the grace starts when that client leaves");
}

/// Work that starts between the deadline's read and the close: the second
/// read, under the fence, finds it.
struct StartsAtTheDeadline(AtomicUsize);

impl Liveness for StartsAtTheDeadline {
    fn live_agents(&self) -> usize {
        usize::from(self.0.fetch_add(1, Ordering::SeqCst) == 1)
    }

    fn live_processes(&self) -> usize {
        0
    }

    fn owner_app_alive(&self) -> bool {
        false
    }
}

#[tokio::test]
async fn idle_exit_work_found_under_the_fence_reopens() {
    let clock = ManualClock::new();
    let presence = Arc::new(ClientPresence::default());
    let liveness = Arc::new(StartsAtTheDeadline(AtomicUsize::new(0)));
    let exit = {
        let (clock, presence, liveness) = (clock.clone(), presence.clone(), liveness.clone());
        tokio::spawn(async move {
            wait_for_idle_exit(&presence, clock, liveness.as_ref(), GRACE, std::future::pending())
                .await;
        })
    };
    settle().await;
    clock.advance(GRACE);
    settle().await;
    assert!(!exit.is_finished(), "exited with work that started at the deadline");
    let client = presence.connect();
    assert!(client.is_some(), "the presence stayed closed");
    drop(client);
    settle().await;
    clock.advance(GRACE);
    settle().await;
    assert!(exit.is_finished());
}

#[test]
fn idle_exit_policy_asks_liveness_only_past_the_grace() {
    let mut policy = IdlePolicy::new(GRACE);
    policy.presence(Duration::ZERO, 0, false);
    let asked = AtomicBool::new(false);
    let early = policy.step(GRACE / 2, || asked.swap(true, Ordering::SeqCst));
    assert_eq!(early, Step::Wait(GRACE / 2));
    assert!(!asked.load(Ordering::SeqCst));
    assert_eq!(policy.step(GRACE, || false), Step::Exit);
    policy.presence(GRACE, 1, true);
    assert_eq!(policy.step(GRACE * 2, || false), Step::Serve);
}

#[test]
fn idle_exit_owner_pid_parse() {
    assert_eq!(OwnerApp::parse(None), OwnerApp::default());
    assert_eq!(OwnerApp::parse(Some("1")), OwnerApp::default());
    assert_eq!(OwnerApp::parse(Some("abc")), OwnerApp::default());
    assert!(!OwnerApp::parse(None).alive());
    #[cfg(unix)]
    {
        let me = std::process::id().to_string();
        assert!(OwnerApp::parse(Some(&me)).alive());
    }
}

#[tokio::test]
async fn idle_exit_hub_counts_a_served_connection() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    assert_eq!(hub.clients.clients(), 0);
    assert_eq!(hub.live_agent_count(), 0);
    assert_eq!(hub.live_process_count(), 0);

    let (in_tx, in_rx) = tokio::sync::mpsc::channel::<String>(4);
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<String>(64);
    let served = tokio::spawn(crate::server::serve_connection(hub.clone(), in_rx, out_tx));
    let ping = r#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/status","params":{}}"#;
    in_tx.send(ping.to_owned()).await.unwrap();
    out_rx.recv().await.expect("a reply");
    assert_eq!(hub.clients.clients(), 1, "a served connection counts");
    drop(in_tx);
    served.await.unwrap();
    assert_eq!(hub.clients.clients(), 0, "a closed connection no longer counts");
}

// The owning app quits (cmux-ad 2026-10-27: after Cmd-Q the app's acpmux kept
// running). Chromium's child processes end when the browser process goes; an
// idle daemon whose app exited serves nobody, so it exits after
// OWNER_EXIT_GRACE, not after a full IDLE_EXIT_GRACE.

#[tokio::test]
async fn idle_exit_soon_after_the_owning_app_quits() {
    let run = Run::start(Facts { owner: AtomicBool::new(true), ..Facts::default() });
    let app = run.presence.connect().expect("the app connects");
    run.advance(GRACE * 2).await;
    assert!(!run.exited(), "exited under its running, connected app");
    // The quit: the app's connection closes, then its process is gone.
    drop(app);
    run.advance(Duration::from_millis(100)).await;
    run.owner_exits().await;
    assert!(!run.exited(), "exited before the owner-exit grace");
    run.advance(OWNER_EXIT_GRACE).await;
    assert!(
        run.exited(),
        "an idle daemon outlived its app's quit by more than {OWNER_EXIT_GRACE:?}"
    );
}

#[tokio::test]
async fn idle_exit_owner_exit_while_a_client_stays_waits_for_it() {
    let run = Run::start(Facts { owner: AtomicBool::new(true), ..Facts::default() });
    let other = run.presence.connect().expect("a client connects");
    run.owner_exits().await;
    run.advance(GRACE * 2).await;
    assert!(!run.exited(), "exited with a client connected");
    drop(other);
    run.advance(OWNER_EXIT_GRACE).await;
    assert!(run.exited(), "the short grace did not follow the last client after the owner's exit");
}

#[tokio::test]
async fn idle_exit_owner_exit_keeps_a_working_daemon() {
    // Keep Sessions Running keeps agents working: a turn outlives the quit.
    let run = Run::start(Facts {
        owner: AtomicBool::new(true),
        agents: AtomicUsize::new(1),
        ..Facts::default()
    });
    run.owner_exits().await;
    run.advance(OWNER_EXIT_GRACE * 10).await;
    assert!(!run.exited(), "exited with a live agent after the owner's exit");
    run.advance(GRACE * 2).await;
    assert!(!run.exited(), "exited with a live agent");
    run.facts.agents.store(0, Ordering::SeqCst);
    run.advance(GRACE).await;
    assert!(run.exited(), "stayed past a full grace after the agent's work ended");
}

#[tokio::test]
async fn idle_exit_without_an_owner_exit_keeps_the_full_grace() {
    let run = Run::start(Facts::default());
    run.advance(OWNER_EXIT_GRACE * 10).await;
    assert!(!run.exited(), "a daemon whose owner did not exit took the short grace");
}

/// `OwnerApp::exited` resolves when a real process (here a child) exits, and
/// at once for one that is already gone.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[tokio::test]
async fn idle_exit_owner_watch_sees_the_process_exit() {
    let mut child =
        std::process::Command::new("/bin/sleep").arg("60").spawn().expect("spawn sleep");
    let owner = OwnerApp::parse(Some(&child.id().to_string()));
    let watch = tokio::spawn(owner.exited());
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!watch.is_finished(), "the watch fired while the owner runs");
    child.kill().expect("kill sleep");
    child.wait().expect("reap sleep");
    tokio::time::timeout(Duration::from_secs(10), watch)
        .await
        .expect("the watch missed the owner's exit")
        .expect("the watch task");
    // Gone before this watch starts (the pid was reaped above).
    tokio::time::timeout(Duration::from_secs(10), owner.exited())
        .await
        .expect("the watch of an owner already gone never fired");
}

/// The daemon's exit with `leftoverDaemonIdleExit` off (every channel's
/// default, and v1.1's): the owning app's quit still ends an idle daemon.
struct OffRun {
    clock: Arc<ManualClock>,
    owner_exit: Option<tokio::sync::oneshot::Sender<()>>,
    exit: tokio::task::JoinHandle<()>,
}

fn start_with_the_feature_off(facts: Arc<Facts>) -> OffRun {
    let clock = ManualClock::new();
    let presence = Arc::new(ClientPresence::default());
    let (owner_exit, exited) = tokio::sync::oneshot::channel::<()>();
    let exit = {
        let clock = clock.clone();
        tokio::spawn(async move {
            let owner = async move {
                if exited.await.is_err() {
                    std::future::pending::<()>().await;
                }
            };
            wait_for_daemon_exit(false, &presence, clock, facts.as_ref(), owner).await;
        })
    };
    OffRun { clock, owner_exit: Some(owner_exit), exit }
}

#[tokio::test]
async fn idle_exit_off_never_exits_while_the_owner_runs() {
    let facts = Arc::new(Facts { owner: AtomicBool::new(true), ..Facts::default() });
    let run = start_with_the_feature_off(facts);
    for _ in 0..3 {
        settle().await;
        run.clock.advance(GRACE);
        settle().await;
    }
    assert!(!run.exit.is_finished(), "the feature off, a daemon exited while its app runs");
}

#[tokio::test]
async fn idle_exit_off_the_owners_quit_ends_an_idle_daemon() {
    let facts = Arc::new(Facts { owner: AtomicBool::new(true), ..Facts::default() });
    let mut run = start_with_the_feature_off(facts.clone());
    settle().await;
    run.clock.advance(GRACE * 2);
    settle().await;
    facts.owner.store(false, Ordering::SeqCst);
    let _ = run.owner_exit.take().expect("one exit").send(());
    settle().await;
    assert!(!run.exit.is_finished(), "exited before the owner-exit grace");
    run.clock.advance(OWNER_EXIT_GRACE);
    settle().await;
    assert!(run.exit.is_finished(), "the feature off, an idle daemon outlived its app's quit");
}

// cp/redesign-quit-helpers (principled audit, R2/R3): the owner's exit is a
// level, not an edge latch. On the base, the first deadline after the quit
// that found live work cleared the latch, so once a Keep Sessions turn ended
// the daemon waited a full IDLE_EXIT_GRACE (10 min) with a dead owner, no
// client and no work: the policy says it must exit.
#[tokio::test]
async fn idle_exit_owner_level_gone_then_work_ends_exits_within_a_minute() {
    let run = Run::start(Facts {
        owner: AtomicBool::new(true),
        agents: AtomicUsize::new(1),
        ..Facts::default()
    });
    run.owner_exits().await;
    run.advance(OWNER_EXIT_GRACE).await;
    assert!(!run.exited(), "exited with a live agent after the owner's exit");
    // The turn that Keep Sessions Running kept ends.
    run.facts.agents.store(0, Ordering::SeqCst);
    run.presence.work_changed();
    run.advance(Duration::from_secs(60)).await;
    assert!(
        run.exited(),
        "a minute after its last work ended, the daemon still runs with no client, \
         no live owner and no work"
    );
}
