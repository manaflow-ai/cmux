//! The daemon's best-effort priority while nobody needs it, on a recording
//! setter (`cargo test -p acpmux idle_priority`).

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::mpsc;

/// A presence whose priority changes are recorded, and a quiet answer the
/// test sets.
struct Rig {
    presence: ClientPresence,
    changes: mpsc::UnboundedReceiver<ProcessPriority>,
    quiet: Arc<AtomicBool>,
    /// Each time the idle task asks whether the daemon is quiet.
    asked: mpsc::UnboundedReceiver<()>,
    refuse: Arc<AtomicBool>,
}

impl Rig {
    fn start() -> Self {
        let presence = ClientPresence::default();
        let (tx, changes) = mpsc::unbounded_channel();
        let refuse = Arc::new(AtomicBool::new(false));
        let refusing = refuse.clone();
        assert!(presence.install_priority(Arc::new(move |priority| {
            if refusing.load(Ordering::SeqCst) {
                return Err(PriorityError::Os { pid: 1, errno: libc::EPERM });
            }
            tx.send(priority).unwrap();
            Ok(())
        })));
        let quiet = Arc::new(AtomicBool::new(true));
        let (asked_tx, asked) = mpsc::unbounded_channel();
        let answer = quiet.clone();
        tokio::spawn(presence.run_idle_priority(move || {
            let _ = asked_tx.send(());
            answer.load(Ordering::SeqCst)
        }));
        Self { presence, changes, quiet, asked, refuse }
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
