//! cp/quit-chief-idle (2026-10-27): after a Cmd-Q the Chief's host, its
//! acpmux and its owner daemon ran on, idle, about 300 MB. The app names
//! itself (`OPTCHAT_OWNER_APP_PID`); when it exits, an idle Chief stops
//! (`brain/owner_exit.rs`, `owner_app.rs`), and live work keeps it: Keep
//! Sessions Running keeps the Chief working.

mod common;

use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::{Input, OWNER_APP_EXITED, PARENT};

fn stopped_for_the_quit(h: &Harness) -> bool {
    h.brain
        .fatal()
        .is_some_and(|fatal| fatal.starts_with(OWNER_APP_EXITED))
}

/// Steps the brain until it stops or `within` passes.
fn step_until_stopped(h: &mut Harness, within: Duration) {
    let deadline = Instant::now() + within;
    while h.brain.fatal().is_none() && Instant::now() < deadline {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
            h.brain.step(input);
        }
    }
}

fn child(session: &str, status: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(serde_json::json!({
        "sessionId": session, "name": "bg", "status": status, "harness": "claude",
        "tags": {"mux.parent": PARENT},
    }))
    .unwrap()
}

#[test]
fn an_idle_chief_stops_when_its_app_quits() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle_posts();
    assert!(h.brain.fatal().is_none());
    h.brain.step(Input::OwnerAppExited);
    assert!(
        stopped_for_the_quit(&h),
        "an idle Chief outlived its app's quit: {:?}, held by {:?}",
        h.brain.fatal(),
        h.brain.owner_exit_held_by()
    );
}

#[test]
fn a_running_turn_keeps_the_chief_until_it_ends() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "a long task");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    h.brain.step(Input::OwnerAppExited);
    assert!(h.brain.fatal().is_none(), "the quit cut a running turn");
    h.agents.hold(false);
    h.agents.release();
    step_until_stopped(&mut h, Duration::from_secs(10));
    assert!(
        stopped_for_the_quit(&h),
        "the Chief did not stop after its turn: {:?}, held by {:?}",
        h.brain.fatal(),
        h.brain.owner_exit_held_by()
    );
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 0")),
        "the turn's reply posted before the stop: {sends:?}"
    );
}

#[test]
fn a_child_at_work_keeps_the_chief_until_it_ends() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.settle_posts();
    h.brain
        .step(Input::from(AgentEvent::Up(vec![child("bg-1", "running")])));
    h.brain.step(Input::OwnerAppExited);
    assert!(h.brain.fatal().is_none(), "the quit ended a child at work");
    h.brain.step(Input::from(AgentEvent::SessionChanged(child(
        "bg-1", "idle",
    ))));
    step_until_stopped(&mut h, Duration::from_secs(10));
    assert!(
        stopped_for_the_quit(&h),
        "the Chief did not stop once its child ended: {:?}, held by {:?}",
        h.brain.fatal(),
        h.brain.owner_exit_held_by()
    );
}

#[test]
fn a_chief_whose_app_runs_never_stops_idle() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle_posts();
    h.brain.on_timer();
    assert!(h.brain.fatal().is_none(), "{:?}", h.brain.fatal());
}

/// The kernel watch: the app's process exits, and the next app named in the
/// pid file is followed until it exits too.
#[test]
fn the_watch_follows_the_next_app_and_reports_the_last_exit() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("owner-app.pid");
    let mut first = std::process::Command::new("sleep")
        .arg("600")
        .spawn()
        .unwrap();
    let mut second = std::process::Command::new("sleep")
        .arg("600")
        .spawn()
        .unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    assert!(optchat_chief::owner_app::watch(
        first.id() as i32,
        file.clone(),
        move || {
            let _ = tx.send(());
        }
    ));
    // The second app opened Home: it serves the host now.
    std::fs::write(&file, format!("{}\n", second.id())).unwrap();
    first.kill().unwrap();
    first.wait().unwrap();
    assert!(
        rx.recv_timeout(Duration::from_millis(300)).is_err(),
        "the host stopped while a newer app still runs"
    );
    second.kill().unwrap();
    second.wait().unwrap();
    rx.recv_timeout(Duration::from_secs(5))
        .expect("the last app's exit was never reported");
}

#[test]
fn the_next_owner_is_another_live_process() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("owner-app.pid");
    let alive = |pid: i32| pid == 77;
    assert_eq!(optchat_chief::owner_app::next_owner(5, &file, &alive), None);
    std::fs::write(&file, "5\n").unwrap();
    assert_eq!(optchat_chief::owner_app::next_owner(5, &file, &alive), None);
    std::fs::write(&file, "78\n").unwrap();
    assert_eq!(optchat_chief::owner_app::next_owner(5, &file, &alive), None);
    std::fs::write(&file, "77\n").unwrap();
    assert_eq!(
        optchat_chief::owner_app::next_owner(5, &file, &alive),
        Some(77)
    );
}

/// The app quits (its process is gone and no newer app took the host over).
fn app_quits(h: &mut Harness) {
    h.brain.step(Input::OwnerAppExited);
}

// cp/redesign-quit-helpers (principled audit, R5): on the base an idle host
// whose conversation link was down waited LINK_WAIT (30 s) after its app
// quit, a hold limit that decided what is delivered. Nothing is lost by
// stopping: the person's messages stay in the owner daemon and the brain's
// outbox is saved with its state, so the next host reads and sends them.
#[test]
fn owner_level_an_idle_chief_whose_link_is_down_stops_when_its_app_quits() {
    let mut h = Harness::new(default_script());
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    app_quits(&mut h);
    assert!(
        stopped_for_the_quit(&h),
        "an idle Chief with no live owner and no work still runs: {:?}, held by {:?}",
        h.brain.fatal(),
        h.brain.owner_exit_held_by()
    );
}
