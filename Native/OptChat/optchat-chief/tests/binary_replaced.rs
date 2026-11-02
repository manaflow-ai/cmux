//! An app update replaces the Chief host's binary on disk while the host keeps
//! running the old code: the relaunched app finds the home's lock held and
//! keeps that host (Leo's Chief, Oct 27: a host from Oct 25, 459 commits
//! behind the app). The host now sees its binary replaced and hands off once
//! no turn runs, as an update's SIGUSR1 handoff does, so the app's watcher
//! starts the new build. It waits for idle with no 10-minute cut: a host that
//! still works is no reason to stop a turn.

mod common;

use std::io::Write;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::{HANDOFF_WHEN_IDLE, Input};
use optchat_chief::update_watch::ExeWatch;

fn until_stopped(h: &mut Harness, within: Duration) -> String {
    let deadline = Instant::now() + within;
    while h.brain.fatal().is_none() {
        assert!(Instant::now() < deadline, "the host did not stop");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
            h.brain.step(input);
        }
        if let Some(at) = h.brain.next_timer()
            && at <= Instant::now()
        {
            h.brain.on_timer();
        }
    }
    h.brain.fatal().unwrap().to_owned()
}

#[test]
fn a_replaced_binary_stops_an_idle_host_at_once() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle_posts();
    h.brain.step(Input::BinaryReplaced);
    let fatal = h.brain.fatal().map(str::to_owned).unwrap_or_default();
    assert!(fatal.contains(HANDOFF_WHEN_IDLE), "{fatal:?}");
}

#[test]
fn a_replaced_binary_waits_for_the_running_turn_past_the_update_deadline() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "a long task");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    // The update handoff's deadline would cut this turn; a replaced binary does not.
    h.brain.set_handoff_deadline(Duration::from_millis(100));
    h.brain.step(Input::BinaryReplaced);
    let until = Instant::now() + Duration::from_millis(500);
    while Instant::now() < until {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
        h.brain.on_timer();
        assert!(
            h.brain.fatal().is_none(),
            "stopped mid-turn: {:?}",
            h.brain.fatal()
        );
    }
    h.agents.hold(false);
    h.agents.release();
    let fatal = until_stopped(&mut h, Duration::from_secs(10));
    assert!(fatal.contains(HANDOFF_WHEN_IDLE), "{fatal}");
    assert!(
        !fatal.contains("deadline"),
        "it waited for the turn: {fatal}"
    );
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 0")),
        "{sends:?}"
    );
}

#[test]
fn the_watch_sees_a_binary_replaced_on_disk() {
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("optchat-chief");
    std::fs::write(&exe, b"build one").unwrap();
    let watch = ExeWatch::new(&exe);
    assert!(!watch.replaced(), "the same file");
    // An update: a new file renamed over the old one (as a bundle swap does).
    let next = dir.path().join("optchat-chief.new");
    std::fs::File::create(&next)
        .unwrap()
        .write_all(b"build two, longer")
        .unwrap();
    std::fs::rename(&next, &exe).unwrap();
    assert!(watch.replaced(), "a new file at the path");
}

#[test]
fn the_watch_waits_while_the_binary_is_missing() {
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("optchat-chief");
    std::fs::write(&exe, b"build one").unwrap();
    let watch = ExeWatch::new(&exe);
    // Mid-update the old bundle is gone and the new one not there yet.
    std::fs::remove_file(&exe).unwrap();
    assert!(!watch.replaced(), "nothing to start yet");
}
