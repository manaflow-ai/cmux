//! A Chief turn survives a lost acpmux connection and a harness that does
//! not start on the first try (user 2026-10-19: "(turn failed on
//! claude-sr2: the acpmux connection was lost during the turn) this error
//! happens very very often"). Every cmux NIGHTLY update relaunch hands the
//! acpmux daemon off (5 times on 2026-10-19), and the `sr2 claude` harness
//! exits while the sr2 gateway answers 502 or refuses. Neither may post a
//! failure or drop the user's message: the cut turn runs again on the
//! resume note once acpmux is back, and a failed `session/new` is tried
//! again with a backoff.

mod common;

use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use serde_json::{Value, json};

/// Turn 0 is cut before its end (no `turn_end`: the harness was still at
/// work when the connection went); later turns run as the default does.
fn cut_first_script() -> Script {
    let full = default_script();
    Box::new(move |turn, blocks| {
        if turn == 0 {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": "Checking."}}),
                ),
            ]
        } else {
            full(turn, blocks)
        }
    })
}

/// Every turn is cut before its end.
fn cut_always_script() -> Script {
    Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "Checking."}}),
            ),
        ]
    })
}

/// Steps every input that arrives within `quiet` of the last one.
fn drain(h: &mut Harness, quiet: Duration) {
    while let Ok(input) = h.rx.recv_timeout(quiet) {
        h.brain.step(input);
    }
}

fn prompt_text(h: &Harness, n: usize) -> String {
    Value::Array(h.agents.inner.lock().unwrap().prompts[n].clone()).to_string()
}

fn failures(h: &Harness) -> Vec<String> {
    h.owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .map(|(_, text)| text)
        .filter(|t| t.contains("turn failed") || t.contains("connection was lost"))
        .collect()
}

#[test]
fn a_turn_cut_by_a_lost_acpmux_connection_resumes_when_acpmux_is_back() {
    let mut h = Harness::new(cut_first_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "please summarize the inbox");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    // The app's update relaunch hands the daemon off: the link goes down,
    // then the running turn hears that its connection is lost.
    h.brain.step(Input::from(AgentEvent::Down));
    h.agents.inner.lock().unwrap().lose = true;
    h.agents.hold(false);
    h.agents.release();
    drain(&mut h, Duration::from_millis(500));

    assert!(
        failures(&h).is_empty(),
        "no failure posted: {:?}",
        failures(&h)
    );
    assert_eq!(
        h.agents.inner.lock().unwrap().prompts.len(),
        1,
        "nothing starts while acpmux is down"
    );
    // The cut turn is saved to run again, also across a host restart.
    let rows = h.chat.state_prefix("host/").unwrap();
    assert!(
        rows.iter()
            .any(|(k, v)| k == "host/resumes" && v.contains("please summarize the inbox")),
        "{rows:?}"
    );

    // The next daemon is up: the cut turn runs again on the resume note.
    h.connect();
    h.settle_posts();
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 2);
    let resumed = prompt_text(&h, 1);
    assert!(resumed.contains("nothing was lost: go on"), "{resumed}");
    assert!(resumed.contains("please summarize the inbox"), "{resumed}");
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 1")),
        "the resumed turn answers: {sends:?}"
    );
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
}

#[test]
fn a_harness_that_closes_at_session_start_is_started_again() {
    let mut h = Harness::new(default_script());
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors_once
        .push_back("session/new: agent process closed".into());
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 0")),
        "{sends:?}"
    );
}

#[test]
fn an_upstream_error_at_session_start_is_tried_again_with_a_backoff() {
    let mut h = Harness::new(default_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner
            .session_errors_once
            .push_back("session/new: API Error: 502 upstream request failed".into());
        inner
            .session_errors_once
            .push_back("session/new: API Error: Connection refused (ECONNREFUSED)".into());
    }
    let began = Instant::now();
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 0")),
        "{sends:?}"
    );
    // Two retries wait between them (no tight loop against a failing upstream).
    assert!(
        began.elapsed() >= Duration::from_millis(500),
        "{:?}",
        began.elapsed()
    );
}

#[test]
fn a_setup_error_at_session_start_fails_at_once() {
    let mut h = Harness::new(default_script());
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors_once
        .push_back("session/new: env key X is not one a session may set".into());
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    let failed = failures(&h);
    assert_eq!(failed.len(), 1, "{failed:?}");
    assert!(failed[0].contains("env key X"), "{failed:?}");
}

#[test]
fn a_connection_that_keeps_dropping_fails_the_turn_after_a_few_resumes() {
    let mut h = Harness::new(cut_always_script());
    h.agents.inner.lock().unwrap().lose_always = true;
    h.connect();
    h.say("user_local", "hi");
    // Each loss is followed by the next daemon coming up.
    for _ in 0..6 {
        drain(&mut h, Duration::from_millis(500));
        if h.brain.is_idle() {
            break;
        }
        h.connect();
    }
    h.settle_posts();
    let prompts = h.agents.inner.lock().unwrap().prompts.len();
    assert_eq!(prompts, 4, "resumed 3 times, not forever");
    let failed = failures(&h);
    assert_eq!(failed.len(), 1, "{failed:?}");
    assert!(failed[0].contains("connection was lost"), "{failed:?}");
}

/// Steps inputs and fires due timers until the brain is idle with no timer.
fn settle_with_timers(h: &mut Harness) {
    let deadline = Instant::now() + WAIT;
    loop {
        assert!(Instant::now() < deadline, "the brain did not settle");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        match h.brain.next_timer() {
            Some(at) => {
                std::thread::sleep(at.saturating_duration_since(Instant::now()));
                h.brain.on_timer();
            }
            None if h.brain.is_idle() => return,
            None => {}
        }
    }
}

#[test]
fn a_turn_cut_by_an_upstream_502_runs_again_after_a_backoff() {
    let mut h = Harness::new(cut_first_script());
    h.brain
        .set_upstream_resume_backoff(vec![Duration::from_millis(300)]);
    h.agents.inner.lock().unwrap().answer_error =
        Some("API Error: 502 upstream request failed. This is a server-side issue".into());
    h.connect();
    h.say("user_local", "check the build");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    let began = Instant::now();
    settle_with_timers(&mut h);
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 2);
    let resumed = prompt_text(&h, 1);
    assert!(resumed.contains("check the build"), "{resumed}");
    assert!(
        began.elapsed() >= Duration::from_millis(300),
        "it waits out the backoff"
    );
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 1")),
        "{sends:?}"
    );
}

/// An update relaunch (a248, 2026-10-20): the app stops the Chief's acpmux
/// first (the running turn hears its link is lost), then stops the host.
/// The next host resumes the cut turn once and answers it once.
#[test]
fn a_turn_cut_by_an_update_relaunch_resumes_in_the_next_host() {
    let mut h = Harness::new(cut_first_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "tell a187 to rebase");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    h.brain.step(Input::from(AgentEvent::Down));
    h.agents.inner.lock().unwrap().lose = true;
    h.agents.hold(false);
    h.agents.release();
    drain(&mut h, Duration::from_millis(500));
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
    // The host stops before the next daemon is up.
    let Harness {
        dir,
        chat,
        owner,
        brain,
        ..
    } = h;
    drop(brain);
    chat.shutdown();
    drop(chat);
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.settle_posts();
    let prompts = h.agents.inner.lock().unwrap().prompts.len();
    assert_eq!(prompts, 1, "the next host runs the cut turn once");
    let resumed = prompt_text(&h, 0);
    assert!(resumed.contains("nothing was lost: go on"), "{resumed}");
    assert!(resumed.contains("tell a187 to rebase"), "{resumed}");
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "answered once: {sends:?}");
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
}

/// The user, 2026-10-20: "(turn failed on claude: the acpmux connection was
/// lost during the turn) i see this error every time i update cmux". An
/// update relaunch mid-turn shows no error anywhere: no failed reply, and
/// the cut turn's run record does not say "failed" with the error.
#[test]
fn an_update_relaunch_mid_turn_shows_no_error_in_the_run() {
    let mut h = Harness::new(cut_first_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "what changed today?");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    h.brain.step(Input::from(AgentEvent::Down));
    h.agents.inner.lock().unwrap().lose = true;
    h.agents.hold(false);
    h.agents.release();
    drain(&mut h, Duration::from_millis(500));
    h.connect();
    h.settle_posts();
    let runs = h.owner.lock().unwrap().runs.clone();
    assert!(!runs.is_empty(), "the turns wrote run records");
    let shown: Vec<&Value> = runs
        .iter()
        .filter(|r| {
            r["status"] == "failed"
                || r["error"]
                    .as_str()
                    .is_some_and(|e| e.contains("connection was lost"))
        })
        .collect();
    assert!(
        shown.is_empty(),
        "no run shows the lost connection: {shown:?}"
    );
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 1")),
        "{sends:?}"
    );
}

/// The user, 2026-10-20: "updates must never cut Chief". An update hands the
/// acpmux daemon off, but the turn's harness runs in an agent host the next
/// daemon adopts: the turn goes on. The Chief must not end that adopted
/// session (its work would be lost and done again); it waits for the turn
/// to end, folds all of it into the memory, and only then runs the resume.
#[test]
fn a_turn_the_next_daemon_adopted_runs_to_its_end_and_is_not_ended() {
    let mut h = Harness::new(cut_first_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "rebase a187 and report");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    let session = h.agents.inner.lock().unwrap().prompt_sessions[0].clone();
    h.brain.step(Input::from(AgentEvent::Down));
    h.agents.inner.lock().unwrap().lose = true;
    h.agents.hold(false);
    h.agents.release();
    drain(&mut h, Duration::from_millis(500));
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_status
        .insert(session.clone(), "running".into());
    // The next daemon is up and has adopted the session: it still runs.
    h.connect();
    drain(&mut h, Duration::from_millis(300));
    {
        let inner = h.agents.inner.lock().unwrap();
        assert!(
            !inner.ended.contains(&session),
            "the adopted turn is not ended while it runs: {:?}",
            inner.ended
        );
        assert_eq!(inner.prompts.len(), 1, "no turn starts while it runs");
    }
    // The adopted turn finishes on its own.
    h.agents.append_events(
        &session,
        vec![
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "a187 rebased and pushed"}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ],
    );
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_status
        .insert(session.clone(), "idle".into());
    let idle: cmux_chief::acp::SessionSummary = serde_json::from_value(json!({
        "sessionId": session, "name": "turn", "harness": "claude", "cwd": "/", "status": "idle",
    }))
    .unwrap();
    h.brain.step(Input::from(AgentEvent::SessionChanged(idle)));
    h.settle_posts();
    assert!(h.agents.inner.lock().unwrap().ended.contains(&session));
    let log = h.log();
    assert!(
        log.iter()
            .any(|(_, t)| t.contains("a187 rebased and pushed")),
        "the adopted turn's work is in the memory"
    );
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
}

/// Steps the brain until it stops (a fatal), at most `within`.
fn until_stopped(h: &mut Harness, within: Duration) -> String {
    let deadline = Instant::now() + within;
    while h.brain.fatal().is_none() {
        assert!(Instant::now() < deadline, "the host did not stop");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
            h.brain.step(input);
        }
    }
    h.brain.fatal().unwrap().to_owned()
}

/// The user, 2026-10-20: updates must never cut the Chief. An update asks
/// the Chief host to hand off when idle (SIGUSR1): the running turn goes on
/// to its end, no new turn starts, and the host stops; the next host
/// answers the message that came in meanwhile.
#[test]
fn a_handoff_when_idle_lets_the_running_turn_end_before_the_host_stops() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "tell a187 to rebase");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    h.brain.step(Input::HandoffWhenIdle);
    assert!(h.brain.fatal().is_none(), "the host waits for its turn");
    h.say("user_local", "and then a188");
    h.agents.hold(false);
    h.agents.release();
    let fatal = until_stopped(&mut h, Duration::from_secs(10));
    assert!(
        fatal.contains(optchat_chief::brain::HANDOFF_WHEN_IDLE),
        "{fatal}"
    );
    assert_eq!(
        h.agents.inner.lock().unwrap().prompts.len(),
        1,
        "no turn starts after the handoff request"
    );
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 0")),
        "{sends:?}"
    );
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
    let Harness {
        dir,
        chat,
        owner,
        brain,
        ..
    } = h;
    drop(brain);
    chat.shutdown();
    drop(chat);
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.settle_posts();
    let prompts = h.agents.inner.lock().unwrap().prompts.len();
    assert_eq!(prompts, 1, "the next host answers the waiting message");
    let text = prompt_text(&h, 0);
    assert!(text.contains("and then a188"), "{text}");
    assert!(
        !text.contains("nothing was lost"),
        "no turn was cut: {text}"
    );
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
}

/// A handoff request on a host with no turn stops it at once.
#[test]
fn a_handoff_when_idle_stops_an_idle_host_at_once() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle_posts();
    h.brain.step(Input::HandoffWhenIdle);
    let fatal = h.brain.fatal().map(str::to_owned).unwrap_or_default();
    assert!(
        fatal.contains(optchat_chief::brain::HANDOFF_WHEN_IDLE),
        "{fatal:?}"
    );
}

/// A turn that does not end by the handoff deadline does not keep the old
/// acpmux forever: the host stops, and the next host adopts the turn.
#[test]
fn a_handoff_when_idle_stops_the_host_at_its_deadline() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "a long task");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    h.brain.set_handoff_deadline(Duration::from_millis(200));
    h.brain.step(Input::HandoffWhenIdle);
    assert!(h.brain.fatal().is_none());
    let deadline = Instant::now() + Duration::from_secs(10);
    while h.brain.fatal().is_none() {
        assert!(
            Instant::now() < deadline,
            "the host did not stop at its deadline"
        );
        let at = h.brain.next_timer().expect("a handoff deadline timer");
        std::thread::sleep(at.saturating_duration_since(Instant::now()));
        h.brain.on_timer();
    }
    let fatal = h.brain.fatal().unwrap();
    assert!(
        fatal.contains(optchat_chief::brain::HANDOFF_WHEN_IDLE),
        "{fatal}"
    );
}
