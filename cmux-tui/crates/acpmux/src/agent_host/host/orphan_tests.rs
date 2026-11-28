use super::{Entry, OrphanStep, Pending, TapDir, hello_waits, needs_a_daemon, orphan_step};
use std::time::Duration;

/// A host with no controller looks at its agent only once its whole wait passed, ends it
/// (after the census) only when nothing is pending, and otherwise looks again a wait later.
#[test]
fn an_orphaned_host_ends_only_an_idle_agent_after_its_wait() {
    let wait = Duration::from_secs(600);
    let idle = Pending::default();
    assert_eq!(orphan_step(wait, Duration::ZERO, idle), OrphanStep::Wait(wait));
    assert_eq!(
        orphan_step(wait, Duration::from_secs(590), idle),
        OrphanStep::Wait(Duration::from_secs(10))
    );
    assert_eq!(orphan_step(wait, wait, idle), OrphanStep::Census);
    assert_eq!(orphan_step(wait, wait * 5, idle), OrphanStep::Census);
    for busy in [
        Pending { requests: 1, ..idle },
        Pending { unwritten: 1, ..idle },
        Pending { unlogged: 1, ..idle },
        Pending { translator: true, ..idle },
        Pending { connections: 1, ..idle },
    ] {
        assert_eq!(orphan_step(wait, wait * 5, busy), OrphanStep::Wait(wait), "{busy:?}");
    }
}

/// Output no daemon logged keeps the host; stderr, raw taps and the exit do not.
#[test]
fn only_what_a_next_daemon_needs_keeps_an_orphaned_host() {
    let msg = serde_json::json!({"jsonrpc": "2.0", "method": "session/update"});
    assert!(needs_a_daemon(&Entry::In { msg: msg.clone() }));
    assert!(needs_a_daemon(&Entry::Tap { dir: TapDir::Out, msg: msg.clone() }));
    assert!(!needs_a_daemon(&Entry::Tap { dir: TapDir::In, msg }));
    assert!(!needs_a_daemon(&Entry::Err { line: "warn".into() }));
    assert!(!needs_a_daemon(&Entry::Exit { code: Some(0) }));
}

/// A daemon that connects while the host ends its harness waits until the exit entry is in
/// the log, so its log has the exit and it never starts a turn on a dying harness. The waiter
/// task marks the leader reaped before the main loop logs the exit, so "reaped" is not
/// "exit in" (orphan_exit `a_daemon_connecting_while_the_harness_ends_is_told_it_exited`,
/// `last_h` 0, red on base). It never waits past the end's deadline, nor while only a daemon
/// can drain the output the buffer cap holds back after the reap (review of #30897).
#[test]
fn a_hello_during_the_end_waits_for_the_exit_entry() {
    // (exit_in, given_up, reaped_and_held_back) -> waits
    assert!(hello_waits(false, false, false), "reaped or not, the exit is not logged yet");
    assert!(!hello_waits(true, false, false), "the exit is in");
    assert!(!hello_waits(false, true, false), "the end stopped waiting for the exit");
    assert!(!hello_waits(false, false, true), "only a daemon can drain the capped output");
}

/// The wedge of a host whose second blocking thread could not be made: its one blocking
/// thread waits on the harness, so work queued behind it never ran and the event loop stopped
/// (2026-11-06, a host spawned under a review box's `pids.max`). A pool capped at one thread
/// stands in for the failed spawn: the read still happens, on the caller's task.
#[test]
fn work_with_no_blocking_thread_free_runs_inline() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let (release, held) = std::sync::mpsc::channel::<()>();
        // The harness waiter: holds the only blocking thread until the test ends.
        let waiter = tokio::task::spawn_blocking(move || held.recv().ok());
        tokio::time::sleep(Duration::from_millis(50)).await;
        let read = tokio::time::timeout(
            Duration::from_secs(10),
            super::blocking_or_inline(Duration::from_millis(100), || 7),
        )
        .await;
        assert_eq!(read.ok(), Some(7), "the read waited for a thread that never came");
        release.send(()).unwrap();
        waiter.await.unwrap();
    });
}

#[test]
fn work_runs_on_a_free_blocking_thread() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let main = std::thread::current().id();
    let ran_on = runtime.block_on(super::blocking_or_inline(Duration::from_secs(10), || {
        std::thread::current().id()
    }));
    assert_ne!(ran_on, main, "a free blocking thread takes the work off the event loop");
}
