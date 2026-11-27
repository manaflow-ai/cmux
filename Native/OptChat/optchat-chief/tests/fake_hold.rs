//! The test fake's turn hold (`FakeAgents::hold`): a held turn waits on the
//! fake's condvar, so letting go of the hold must wake it. Before
//! 2026-11-20 `hold(false)` set the flag with no wake, and a held turn
//! answered only when some other call happened to wake it: carried_steer
//! made none and timed out on every Linux run (3 of its 4 tests).

mod common;

use std::time::{Duration, Instant};

use common::*;

#[test]
fn letting_go_of_a_hold_wakes_the_held_turn() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "one");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.poll_step();
    }
    // The held turn's thread is waiting by now.
    std::thread::sleep(Duration::from_millis(200));
    h.agents.hold(false);
    let deadline = Instant::now() + Duration::from_secs(5);
    while h.agents.inner.lock().unwrap().answered_turns == 0 {
        assert!(
            Instant::now() < deadline,
            "the held turn did not answer after hold(false)"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
