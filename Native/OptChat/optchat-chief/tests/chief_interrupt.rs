//! A person's message to a busy Chief interrupts the running turn at once
//! and the next turn answers it (Lawrence 2026-10-21: "we need to
//! immediately interrupt and steer / no fake messages"). The turn is
//! stopped (`session/cancel`, even while a tool call runs), posts nothing,
//! and the next turn starts the moment it ends with the message. No
//! "Got it. The Chief is busy" receipt is ever posted. A subagent's report
//! still only steers into the running turn and never stops it.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use optchat_chief::voice;
use serde_json::{Value, json};

/// The Chief's first turn sits in a tool call that never finishes (no
/// result, no turn end); every later turn answers "answer N". A subagent's
/// turn (its task says REPORT-TASK) ends with "built it".
fn busy_first_turn() -> Script {
    let base = default_script();
    Box::new(move |turn, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        if text.contains("start the work") && !text.contains("use the other branch") {
            return vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": "Checking."}}),
                ),
                update(
                    "tool_call",
                    json!({"toolCallId": "long", "title": "Bash", "rawInput": {"command": "sleep 600"}, "_meta": {"claude": {"tool": "Bash"}}}),
                ),
            ];
        }
        if text.contains("REPORT-TASK") {
            return vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": "built it"}}),
                ),
                json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
            ];
        }
        base(turn, blocks)
    })
}

/// A Chief turn runs for "start the work", held at the fake agent, with its
/// session started (a steer could reach it) and its prompt sent.
fn busy(h: &mut Harness) {
    h.agents.hold(true);
    let before = h.agents.inner.lock().unwrap().prompts.len();
    h.say("user_local", "start the work");
    let deadline = Instant::now() + Duration::from_secs(10);
    // The runner records the session (`TurnProgress`) just before it sends
    // the prompt: step while inputs come, never block on one more.
    while h.agents.inner.lock().unwrap().prompts.len() <= before
        || h.brain
            .state()
            .turn
            .as_ref()
            .and_then(|t| t.session_id.clone())
            .is_none()
    {
        assert!(Instant::now() < deadline, "the Chief turn never started");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
}

/// The text of every prompt the agent got, in order.
fn prompt_texts(h: &Harness) -> Vec<String> {
    let inner = h.agents.inner.lock().unwrap();
    inner
        .prompts
        .iter()
        .map(|b| serde_json::to_string(b).unwrap())
        .collect()
}

/// The text of every steer the agent got, in order.
fn steer_texts(h: &Harness) -> Vec<String> {
    let inner = h.agents.inner.lock().unwrap();
    inner
        .steers
        .iter()
        .map(|(_, b)| serde_json::to_string(b).unwrap())
        .collect()
}

/// Nothing the Chief posted speaks in a voice (no desk receipt), and no
/// post reads "busy" or carries the stopped turn's words.
fn assert_no_receipt(h: &Harness) {
    let sends = h.owner.lock().unwrap().sends();
    for (key, text) in &sends {
        assert_eq!(voice::of(key), None, "no voiced post: {sends:?}");
        assert!(!text.contains("busy"), "no receipt: {sends:?}");
        assert!(
            !text.contains("reads your message next"),
            "no receipt: {sends:?}"
        );
    }
}

#[test]
fn busy_chief_stops_at_once_for_a_persons_message_even_mid_tool_call() {
    let mut h = Harness::new(busy_first_turn());
    // The session could take a steer: the message still stops the turn
    // (a steer is read only at the next tool boundary, and this tool call
    // never ends).
    h.agents.inner.lock().unwrap().steering = true;
    h.connect();
    busy(&mut h);
    h.say("user_local", "use the other branch");
    h.agents.wait_cancels(1);
    assert!(
        steer_texts(&h).is_empty(),
        "the message is not steered into the turn it stops: {:?}",
        steer_texts(&h)
    );

    h.agents.hold(false);
    h.settle_posts();
    let prompts = prompt_texts(&h);
    assert_eq!(
        prompts.len(),
        2,
        "one stopped turn, one new turn: {prompts:?}"
    );
    assert!(
        prompts[1].contains("use the other branch"),
        "the next turn carries the message: {}",
        prompts[1]
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "only the next turn's reply: {sends:?}");
    assert!(sends[0].1.contains("answer 1"), "{sends:?}");
    assert!(
        sends.iter().all(|(_, t)| !t.contains("Checking.")
            && !t.contains("turn failed")
            && !t.contains("stopped")),
        "the stopped turn posts nothing: {sends:?}"
    );
    assert_no_receipt(&h);
}

#[test]
fn busy_chief_answers_every_message_that_stopped_it_in_the_next_turn() {
    let mut h = Harness::new(busy_first_turn());
    h.agents.inner.lock().unwrap().steering = true;
    h.connect();
    busy(&mut h);
    h.say("user_local", "hello?");
    h.say("user_local", "use the other branch");
    h.agents.wait_cancels(1);
    h.agents.hold(false);
    h.settle_posts();
    let prompts = prompt_texts(&h);
    assert_eq!(prompts.len(), 2, "{prompts:?}");
    assert!(prompts[1].contains("hello?"), "{}", prompts[1]);
    assert!(
        prompts[1].contains("use the other branch"),
        "{}",
        prompts[1]
    );
    assert!(steer_texts(&h).is_empty(), "{:?}", steer_texts(&h));
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "one answer for both: {sends:?}");
    assert_no_receipt(&h);
}

/// The turn the message stops may end in an error instead of a clean
/// cancel (the harness dies on the cancel): it still posts nothing, no
/// "turn failed" line, and is not run again; the next turn answers.
#[test]
fn busy_chief_stopped_turn_that_ends_in_an_error_posts_nothing() {
    let mut h = Harness::new(busy_first_turn());
    h.connect();
    busy(&mut h);
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.ignore_cancels = usize::MAX;
        inner.answer_error = Some("the agent process exited".into());
    }
    h.say("user_local", "use the other branch");
    h.agents.wait_cancels(1);
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    let prompts = prompt_texts(&h);
    assert_eq!(
        prompts.len(),
        2,
        "no retry of the stopped turn: {prompts:?}"
    );
    assert!(
        prompts[1].contains("use the other branch"),
        "{}",
        prompts[1]
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "only the next turn's reply: {sends:?}");
    assert!(sends[0].1.contains("answer 1"), "{sends:?}");
    assert_no_receipt(&h);
}

/// A message that comes while the turn's session is still starting is never
/// steered into it once it starts: the turn stops, the next one answers.
#[test]
fn busy_chief_stops_for_a_message_before_its_session_starts() {
    let mut h = Harness::new(busy_first_turn());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.steering = true;
        inner.slow_session = Some((TURN_PREFIX.into(), Duration::from_millis(500)));
    }
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "start the work");
    let deadline = Instant::now() + Duration::from_secs(10);
    while h.brain.state().turn.is_none() {
        assert!(Instant::now() < deadline, "the Chief turn never started");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    // The runner is past its start: it looks the session name up just
    // before `session/new`, which `slow_session` holds for 500 ms.
    while h.agents.inner.lock().unwrap().finds.is_empty() {
        assert!(Instant::now() < deadline, "the runner never started");
        std::thread::sleep(Duration::from_millis(5));
    }
    h.say("user_local", "use the other branch");
    h.agents.wait_cancels(1);
    h.agents.hold(false);
    h.settle_posts();
    assert!(steer_texts(&h).is_empty(), "{:?}", steer_texts(&h));
    let prompts = prompt_texts(&h);
    assert_eq!(prompts.len(), 2, "{prompts:?}");
    assert!(
        prompts[1].contains("use the other branch"),
        "{}",
        prompts[1]
    );
    assert_no_receipt(&h);
}

fn spawner(h: &Harness) -> Arc<Spawner> {
    Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    ))
}

fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

/// The subagent's session (the one tagged as a subagent).
fn sub_session(h: &Harness) -> Option<String> {
    let inner = h.agents.inner.lock().unwrap();
    let k = inner
        .specs
        .iter()
        .position(|s| s.tags.contains_key("optchat.subagent"))?;
    Some(format!("s{}", k + 1))
}

fn idle(session: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
    }))
    .unwrap()
}

#[test]
fn busy_chief_takes_a_subagents_report_as_a_steer_never_a_stop() {
    let mut h = Harness::new(busy_first_turn());
    h.agents.hold(true);
    h.connect();
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    run(&mut h, move || {
        a.spawn(vec!["REPORT-TASK build it".into()], None)
    })
    .unwrap();
    // The subagent's prompt is the first; the Chief's turn is the next.
    h.agents.wait_prompts(1);
    busy(&mut h);
    let chief_session = h
        .brain
        .state()
        .turn
        .as_ref()
        .and_then(|t| t.session_id.clone())
        .expect("the Chief turn's session");
    h.agents.inner.lock().unwrap().steering = true;
    // Only the subagent's turn runs (released 1 frees prompt 0).
    h.agents.release();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    loop {
        let steered = steer_texts(&h).iter().any(|t| t.contains("[a1]"));
        if steered {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the report never reached the Chief turn: {:?}",
            h.log()
        );
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        if !idle_sent && let Some(session) = sub_session(&h) {
            idle_sent = true;
            h.brain
                .step(Input::from(AgentEvent::SessionChanged(idle(&session))));
        }
    }
    let cancels = h.agents.inner.lock().unwrap().cancels.clone();
    assert!(
        !cancels.contains(&chief_session),
        "a report never stops the Chief's turn: {cancels:?}"
    );
    assert_no_receipt(&h);
}

/// The stopped turn's own end can race the stop: acpmux ends it normally
/// (the cancel came too late) with an answer. The stop was accepted, so
/// that stale answer is never posted; the next turn answers.
#[test]
fn busy_chief_stopped_turn_that_still_ends_normally_posts_nothing() {
    let mut h = Harness::new(busy_first_turn());
    h.connect();
    busy(&mut h);
    h.agents.inner.lock().unwrap().ignore_cancels = usize::MAX;
    h.say("user_local", "use the other branch");
    h.agents.wait_cancels(1);
    let session = h
        .brain
        .state()
        .turn
        .as_ref()
        .and_then(|t| t.session_id.clone())
        .expect("the Chief turn's session");
    // The tool call finishes and the turn answers anyway.
    h.agents.append_events(
        &session,
        vec![
            update(
                "tool_call_update",
                json!({"toolCallId": "long", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "done"}}]}),
            ),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "STALE ANSWER"}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ],
    );
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    let prompts = prompt_texts(&h);
    assert_eq!(prompts.len(), 2, "{prompts:?}");
    assert!(
        prompts[1].contains("use the other branch"),
        "{}",
        prompts[1]
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "only the next turn's reply: {sends:?}");
    assert!(sends[0].1.contains("answer 1"), "{sends:?}");
    assert!(
        sends.iter().all(|(_, t)| !t.contains("STALE ANSWER")),
        "the stopped turn's answer is not posted: {sends:?}"
    );
    assert_no_receipt(&h);
}

/// Each conversation keeps what its stopped turn owes: another
/// conversation's stopped turn never takes it, overwrites it or drops its
/// `ask` (a turn stopped in A while B waits, then B's turn stopped too).
#[test]
fn a_stopped_turns_carry_stays_with_its_conversation() {
    use optchat_chief::state::HostState;
    let a = Some("conv_a".to_owned());
    let b = Some("conv_b".to_owned());
    let mut state = HostState::default();
    state.carry(a.clone(), vec!["a1".into()], true);
    state.carry(b.clone(), vec!["b1".into()], false);
    state.carry(b.clone(), vec!["b2".into()], false);
    assert_eq!(state.carried(&a), (vec!["a1".to_owned()], true));
    assert_eq!(
        state.carried(&b),
        (vec!["b1".to_owned(), "b2".to_owned()], false)
    );
    // B's next turn takes its own and leaves A's, through a save.
    state.take_carry(&b);
    let saved: HostState = serde_json::from_value(serde_json::to_value(&state).unwrap()).unwrap();
    assert_eq!(saved.carried(&a), (vec!["a1".to_owned()], true));
    assert_eq!(saved.carried(&b), (Vec::new(), false));
}

/// acpmux relaunches while the owner's message stops a turn: the next
/// daemon is up before the stopped turn's runner reports its end (lost
/// link). No other Up follows, so the next turn still starts at once, and
/// the stopped turn's session is folded and ended.
#[test]
fn busy_chief_stopped_turn_ending_after_a_fast_reconnect_lets_the_next_turn_start() {
    let mut h = Harness::new(busy_first_turn());
    h.connect();
    busy(&mut h);
    h.agents.inner.lock().unwrap().ignore_cancels = usize::MAX;
    h.say("user_local", "use the other branch");
    h.agents.wait_cancels(1);
    h.brain.step(Input::from(AgentEvent::Down));
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    h.agents.inner.lock().unwrap().lose = true;
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    let prompts = prompt_texts(&h);
    assert_eq!(prompts.len(), 2, "{prompts:?}");
    assert!(
        prompts[1].contains("use the other branch"),
        "{}",
        prompts[1]
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "only the next turn's reply: {sends:?}");
    assert!(sends[0].1.contains("answer 1"), "{sends:?}");
    let ended = h.agents.inner.lock().unwrap().ended.clone();
    assert!(ended.contains(&"s1".to_owned()), "{ended:?}");
}

/// The host restarts after the owner's message asked the turn to stop but
/// before it ended, while its session still runs in acpmux. The stop was
/// saved: the next host folds and ends that session at once instead of
/// waiting for it, and a turn answers the message.
#[test]
fn busy_chief_restarted_before_its_stop_lands_never_waits_for_the_stopped_turn() {
    let mut h = Harness::new(busy_first_turn());
    h.connect();
    busy(&mut h);
    h.agents.inner.lock().unwrap().ignore_cancels = usize::MAX;
    h.say("user_local", "use the other branch");
    h.agents.wait_cancels(1);
    assert!(
        h.brain.state().turn.as_ref().is_some_and(|t| t.stopped),
        "the stop is saved before the turn ends"
    );
    let (specs, events) = {
        let inner = h.agents.inner.lock().unwrap();
        (inner.specs.clone(), inner.events.clone())
    };
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
    {
        // The next acpmux still runs the stopped turn's session.
        let mut inner = h.agents.inner.lock().unwrap();
        inner.specs = specs;
        inner.events = events;
    }
    h.connect();
    h.settle_posts();
    let ended = h.agents.inner.lock().unwrap().ended.clone();
    assert!(ended.contains(&"s1".to_owned()), "{ended:?}");
    let prompts = prompt_texts(&h);
    assert!(
        prompts.iter().any(|p| p.contains("use the other branch")),
        "{prompts:?}"
    );
    let sends = h.owner.lock().unwrap().sends();
    assert!(!sends.is_empty(), "the message is answered");
    assert!(
        sends.iter().all(|(_, t)| !t.contains("turn failed")),
        "{sends:?}"
    );
}
