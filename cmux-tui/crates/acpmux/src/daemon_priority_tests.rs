//! The daemon's best-effort priority while nobody needs it, on a recording
//! setter (`cargo test -p acpmux idle_priority`).

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::mpsc;

/// A presence whose priority changes are recorded, and a quiet answer the
/// test sets.
struct Rig {
    presence: Arc<ClientPresence>,
    changes: mpsc::UnboundedReceiver<ProcessPriority>,
    quiet: Arc<AtomicBool>,
    /// Each time the idle task asks whether the daemon is quiet.
    asked: mpsc::UnboundedReceiver<()>,
    refuse: Arc<AtomicBool>,
    /// Set: the next ask answers, then a start begins (it counts, so quiet
    /// turns false, and calls `foreground`) before the idle task applies.
    start_during_ask: Arc<AtomicBool>,
}

impl Rig {
    fn start() -> Self {
        Self::start_quiet(true)
    }

    fn start_quiet(quiet: bool) -> Self {
        let presence = Arc::new(ClientPresence::default());
        let (tx, changes) = mpsc::unbounded_channel();
        let refuse = Arc::new(AtomicBool::new(false));
        let refusing = refuse.clone();
        assert!(presence.install_priority(Arc::new(
            move |priority, _lowered: &mut SelfLowered| {
                if refusing.load(Ordering::SeqCst) {
                    return Err(PriorityError::Os { pid: 1, errno: libc::EPERM });
                }
                tx.send(priority).unwrap();
                Ok(())
            }
        )));
        let quiet = Arc::new(AtomicBool::new(quiet));
        let (asked_tx, asked) = mpsc::unbounded_channel();
        let answer = quiet.clone();
        let start_during_ask = Arc::new(AtomicBool::new(false));
        let starting = start_during_ask.clone();
        let starter = Arc::downgrade(&presence);
        tokio::spawn(presence.run_idle_priority(move || {
            let quiet = answer.load(Ordering::SeqCst);
            if starting.swap(false, Ordering::SeqCst) {
                answer.store(false, Ordering::SeqCst);
                starter.upgrade().unwrap().foreground();
            }
            let _ = asked_tx.send(());
            quiet
        }));
        Self { presence, changes, quiet, asked, refuse, start_during_ask }
    }

    async fn next_change(&mut self) -> ProcessPriority {
        tokio::time::timeout(Duration::from_secs(10), self.changes.recv())
            .await
            .expect("a priority change")
            .unwrap()
    }

    async fn next_ask(&mut self) {
        tokio::time::timeout(Duration::from_secs(10), self.asked.recv())
            .await
            .expect("the idle task asked")
            .unwrap();
    }
}

#[tokio::test]
async fn idle_priority_is_best_effort_without_clients_and_normal_in_the_connect_turn() {
    let mut rig = Rig::start();
    assert_eq!(rig.next_change().await, ProcessPriority::BestEffort);
    assert!(rig.presence.background());

    let guard = rig.presence.connect().expect("taken");
    // Back before connect returned: no await in between.
    assert_eq!(rig.changes.try_recv(), Ok(ProcessPriority::UserVisible));
    assert!(!rig.presence.background());

    // A second client changes nothing; the last one leaving goes back.
    let second = rig.presence.connect().unwrap();
    assert!(rig.changes.try_recv().is_err());
    drop(guard);
    drop(second);
    assert_eq!(rig.next_change().await, ProcessPriority::BestEffort);
}

#[tokio::test]
async fn idle_priority_stays_normal_while_an_agent_runs() {
    let mut rig = Rig::start();
    assert_eq!(rig.next_change().await, ProcessPriority::BestEffort);
    rig.next_ask().await;
    rig.quiet.store(false, Ordering::SeqCst);
    let guard = rig.presence.connect().unwrap();
    assert_eq!(rig.changes.try_recv(), Ok(ProcessPriority::UserVisible));
    drop(guard);
    // The task asked after the last client left; an agent runs: no change.
    rig.next_ask().await;
    tokio::task::yield_now().await;
    assert!(rig.changes.try_recv().is_err());
    assert!(!rig.presence.background());
}

#[tokio::test]
async fn idle_priority_foreground_puts_back_only_a_background_daemon() {
    let mut rig = Rig::start();
    assert_eq!(rig.next_change().await, ProcessPriority::BestEffort);
    rig.presence.foreground();
    assert_eq!(rig.changes.try_recv(), Ok(ProcessPriority::UserVisible));
    rig.presence.foreground();
    assert!(rig.changes.try_recv().is_err(), "already normal: nothing to put back");
}

#[tokio::test]
async fn idle_priority_a_refused_change_is_tried_again_on_the_next_turn() {
    let mut rig = Rig::start();
    assert_eq!(rig.next_change().await, ProcessPriority::BestEffort);
    rig.refuse.store(true, Ordering::SeqCst);
    let guard = rig.presence.connect().expect("a refused change still serves the client");
    assert!(rig.presence.background(), "the refused change is not recorded");
    rig.refuse.store(false, Ordering::SeqCst);
    rig.presence.foreground();
    assert_eq!(rig.changes.try_recv(), Ok(ProcessPriority::UserVisible));
    drop(guard);
}

#[tokio::test]
async fn idle_priority_without_an_installed_setter_changes_nothing() {
    let presence = ClientPresence::default();
    let asked = Arc::new(AtomicBool::new(false));
    let flag = asked.clone();
    let task = tokio::spawn(presence.run_idle_priority(move || {
        flag.store(true, Ordering::SeqCst);
        true
    }));
    drop(presence.connect().unwrap());
    tokio::task::yield_now().await;
    presence.foreground();
    assert!(!presence.background());
    assert!(!asked.load(Ordering::SeqCst), "the feature is off: nothing is asked");
    task.abort();
}

#[tokio::test]
async fn idle_priority_goes_best_effort_when_work_ends_without_a_presence_change() {
    // A daemon that starts with no client while an agent runs (or startup
    // work is not done) is normal; the agent ends with no client around.
    let mut rig = Rig::start_quiet(false);
    rig.next_ask().await;
    tokio::task::yield_now().await;
    assert!(rig.changes.try_recv().is_err(), "busy: normal");
    rig.quiet.store(true, Ordering::SeqCst);
    rig.presence.work_changed();
    assert_eq!(rig.next_change().await, ProcessPriority::BestEffort);
    assert!(rig.presence.background());
}

#[tokio::test]
async fn idle_priority_goes_normal_when_work_starts_without_a_client() {
    let mut rig = Rig::start();
    assert_eq!(rig.next_change().await, ProcessPriority::BestEffort);
    // A process this daemon started still runs work after the client left.
    rig.quiet.store(false, Ordering::SeqCst);
    rig.presence.work_changed();
    assert_eq!(rig.next_change().await, ProcessPriority::UserVisible);
    assert!(!rig.presence.background());
}

#[tokio::test]
async fn idle_priority_a_start_after_the_quiet_read_keeps_the_daemon_normal() {
    let mut rig = Rig::start_quiet(false);
    rig.next_ask().await;
    // The next ask reads quiet, then a pooled start counts itself and calls
    // `foreground` before the idle task applies its answer: not applied.
    rig.quiet.store(true, Ordering::SeqCst);
    rig.start_during_ask.store(true, Ordering::SeqCst);
    rig.presence.work_changed();
    rig.next_ask().await;
    // It reads again: the start runs, so normal.
    rig.next_ask().await;
    tokio::task::yield_now().await;
    assert!(rig.changes.try_recv().is_err(), "never best-effort while the start forks");
    assert!(!rig.presence.background());
}
