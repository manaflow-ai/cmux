//! A person's message sent while the Chief's turn runs (user 2026-10-21:
//! "we need to immediately interrupt and steer", "no fake messages"). It is
//! steered into the running turn at once; when the turn cannot take it now,
//! or has not read it by the steer deadline (a long tool call, a long
//! think), the turn is interrupted and the next one starts with it. The host
//! never posts a message of its own about it (the old front desk receipt
//! "Got it. The Chief is busy with a turn ... reads your message next.").

mod common;
use common::*;

use std::time::Duration;

use optchat_chief::voice;

/// Turn 0 sits in a long tool call (no result, no turn end yet), as Claude
/// Code does in a long `sleep` or build; later turns run the default.
fn long_tool_script() -> Script {
    let rest = default_script();
    Box::new(move |turn, blocks| {
        if turn > 0 {
            return rest(turn, blocks);
        }
        vec![
            serde_json::json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "tool_call",
                serde_json::json!({"toolCallId": "t0", "title": "Bash", "rawInput": {"command": "sleep 600"}, "_meta": {"claude": {"tool": "Bash"}}}),
            ),
        ]
    })
}

/// A turn is running for `text`, held at the fake agent.
fn running(h: &mut Harness, text: &str) {
    h.agents.hold(true);
    h.connect();
    h.say("user_local", text);
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
}

/// Fires every timer that is due within `within`.
fn pass(h: &mut Harness, within: Duration) {
    let until = std::time::Instant::now() + within;
    while let Some(at) = h.brain.next_timer().filter(|at| *at <= until) {
        std::thread::sleep(at.saturating_duration_since(std::time::Instant::now()));
        h.brain.on_timer();
    }
    std::thread::sleep(until.saturating_duration_since(std::time::Instant::now()));
}

/// Everything the host posted that is not the Chief's own words.
fn host_posts(h: &Harness) -> Vec<(String, String)> {
    h.owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .filter(|(key, text)| voice::of(key).is_some() || text.contains("busy with a turn"))
        .collect()
}

/// The text of every block of prompt `n`.
fn prompt_text(h: &Harness, n: usize) -> String {
    serde_json::to_string(&h.agents.inner.lock().unwrap().prompts[n]).unwrap()
}

/// Steps one input if one comes soon, and fires due timers.
fn tick(h: &mut Harness) {
    if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
        h.brain.step(input);
    }
    if h.brain
        .next_timer()
        .is_some_and(|at| at <= std::time::Instant::now())
    {
        h.brain.on_timer();
    }
}

/// Steps the brain until the fake agent saw `n` cancels.
fn until_cancels(h: &mut Harness, n: usize) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while h.agents.inner.lock().unwrap().cancels.len() < n {
        assert!(std::time::Instant::now() < deadline, "no cancel {n}");
        tick(h);
    }
}

/// Steps the brain until the fake agent saw `n` prompts.
fn until_prompts(h: &mut Harness, n: usize) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while h.agents.inner.lock().unwrap().prompts.len() < n {
        assert!(std::time::Instant::now() < deadline, "no prompt {n}");
        tick(h);
    }
}

#[test]
fn mid_turn_a_message_that_waits_on_a_running_turn_posts_nothing_from_the_host() {
    let mut h = Harness::new(default_script());
    h.agents.inner.lock().unwrap().steering = true;
    h.brain.set_steer_deadline(Some(Duration::from_millis(20)));
    running(&mut h, "fix the sidebar");
    h.say("user_local", "hello?");
    h.say("user_local", "are you there?");
    pass(&mut h, Duration::from_millis(200));
    assert!(host_posts(&h).is_empty(), "{:?}", host_posts(&h));
}

#[test]
fn mid_turn_a_steer_the_turn_reads_in_time_keeps_the_turn() {
    let mut h = Harness::new(default_script());
    h.agents.inner.lock().unwrap().steering = true;
    h.brain.set_steer_deadline(Some(Duration::from_millis(20)));
    running(&mut h, "fix the sidebar");
    h.say("user_local", "and the composer");
    h.agents.wait_steers(1);
    pass(&mut h, Duration::from_millis(200));
    assert!(h.agents.inner.lock().unwrap().cancels.is_empty());
    assert!(host_posts(&h).is_empty(), "{:?}", host_posts(&h));
}

#[test]
fn mid_turn_a_steer_left_unread_past_the_deadline_interrupts_and_the_next_turn_takes_it() {
    let mut h = Harness::new(long_tool_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.steering = true;
        // Claude Code is in a long tool call: it reads the steer only when
        // the turn ends.
        inner.steer_at_end = true;
    }
    h.brain.set_steer_deadline(Some(Duration::from_millis(20)));
    running(&mut h, "fix the sidebar");
    h.say("user_local", "stop, do the composer first");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while h.agents.inner.lock().unwrap().steers.is_empty() {
        assert!(std::time::Instant::now() < deadline, "no steer");
        tick(&mut h);
    }
    pass(&mut h, Duration::from_millis(100));
    until_cancels(&mut h, 1);
    h.agents.hold(false);
    until_prompts(&mut h, 2);
    assert!(
        prompt_text(&h, 1).contains("stop, do the composer first"),
        "{}",
        prompt_text(&h, 1)
    );
    h.settle_posts();
    assert!(host_posts(&h).is_empty(), "{:?}", host_posts(&h));
}

#[test]
fn mid_turn_a_turn_that_cannot_be_steered_is_interrupted_at_once() {
    let mut h = Harness::new(long_tool_script());
    // acpmux refuses the steer (steer.unavailable).
    h.agents.inner.lock().unwrap().steering = false;
    running(&mut h, "fix the sidebar");
    h.say("user_local", "wait, wrong repo");
    until_cancels(&mut h, 1);
    h.agents.hold(false);
    until_prompts(&mut h, 2);
    assert!(
        prompt_text(&h, 1).contains("wait, wrong repo"),
        "{}",
        prompt_text(&h, 1)
    );
    h.settle_posts();
    assert!(host_posts(&h).is_empty(), "{:?}", host_posts(&h));
}
