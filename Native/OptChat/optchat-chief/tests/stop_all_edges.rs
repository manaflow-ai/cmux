//! chief.stop {all} and {restart} at their edges (#22978's follow-ups): a
//! cancel acpmux refuses stops nothing, so it is reported as an error and
//! the subagent stays as it was; a subagent still starting when "Stop all
//! agents" comes is named and stopped as soon as its task is sent, and
//! again when its task turn really starts (a cancel that reached acpmux
//! before the prompt was lost); a cancel refused then is told to the Chief.

mod common;

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::state::{SubRecord, SubStatus};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{ControlCall, Orchestrator};
use optchat_chief::trace::Trace;
use serde_json::{Value, json};

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

/// Steps the brain until `worker` is done and its inputs are in.
fn pump<T>(h: &mut Harness, worker: std::thread::JoinHandle<T>) -> T {
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
    worker.join().unwrap()
}

fn sub(h: &Harness, id: &str) -> SubRecord {
    h.brain.state().sub(id).expect(id).1.clone()
}

fn stop_all(h: &mut Harness) -> Value {
    let (reply, answer) = channel();
    h.brain.step(Input::StopAll { reply });
    answer.try_recv().expect("chief.stop {all} answers at once")
}

fn restart(h: &mut Harness, names: &[&str]) -> Value {
    let (reply, answer) = channel();
    h.brain.step(Input::RestartSubagents {
        names: names.iter().map(|n| n.to_string()).collect(),
        reply,
    });
    answer
        .try_recv()
        .expect("chief.stop {restart} answers at once")
}

/// a1 is spawned and at work, its turn held at the fake agent.
fn a1_at_work(h: &mut Harness) {
    h.agents.hold(true);
    let a = spawner(h);
    let spawned = pump(
        h,
        std::thread::spawn(move || a.spawn(vec!["one".into()], None)),
    )
    .unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    assert_eq!(sub(h, "a1").status, SubStatus::Running);
}

/// a1's spawn is under way: the brain registered it (starting, no session
/// yet) and has not seen its session. Its worker goes on.
fn a1_starting(h: &mut Harness) -> std::thread::JoinHandle<Result<String, String>> {
    h.agents.hold(true);
    let a = spawner(h);
    let worker = std::thread::spawn(move || a.spawn(vec!["one".into()], None));
    while h.brain.state().sub("a1").is_none() {
        let input =
            h.rx.recv_timeout(Duration::from_secs(5))
                .expect("the spawn registers a1");
        h.brain.step(input);
    }
    let a1 = sub(h, "a1");
    assert_eq!(a1.status, SubStatus::Starting);
    assert!(a1.session_id.is_none(), "no session yet");
    worker
}

/// a1's spawn has its session (the brain saw it) and its task is not sent
/// yet: the brain has not seen its first prompt go out.
fn a1_before_its_task(h: &mut Harness) -> std::thread::JoinHandle<Result<String, String>> {
    let worker = a1_starting(h);
    while sub(h, "a1").session_id.is_none() {
        let input =
            h.rx.recv_timeout(Duration::from_secs(5))
                .expect("a1's session starts");
        h.brain.step(input);
    }
    assert!(sub(h, "a1").awaiting_task, "its task is not sent yet");
    worker
}

/// A turn that records nothing until the test says it starts
/// (`task_turn_starts`), as a prompt waiting in acpmux's queue does.
fn quiet_script() -> Script {
    Box::new(|_, _| Vec::new())
}

/// a1's task turn starts at acpmux: the echo of its task prompt
/// (`user_message` with its prompt id), then `turn_started`.
fn task_turn_starts(h: &Harness, session: &str) {
    let prompt = {
        let inner = h.agents.inner.lock().unwrap();
        inner
            .prompt_sessions
            .iter()
            .zip(&inner.prompt_ids)
            .find(|(s, _)| *s == session)
            .map(|(_, p)| p.clone())
            .expect("a1's task prompt was sent")
    };
    h.agents.push_events(
        session,
        vec![
            json!({"dir": "mux", "kind": "user_message", "msg": {"promptId": prompt}}),
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        ],
    );
}

/// Steps the brain until `done`, at most 10 s.
fn step_until(h: &mut Harness, what: &str, done: impl Fn(&Harness) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done(h) {
        assert!(Instant::now() < deadline, "timed out: {what}");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
}

fn cancels(h: &Harness) -> Vec<String> {
    h.agents.inner.lock().unwrap().cancels.clone()
}

fn traces(h: &Harness) -> Vec<Value> {
    let dir = h.dir.path().join("traces");
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
        let text = std::fs::read_to_string(entry.path()).unwrap();
        out.extend(text.lines().filter_map(|l| serde_json::from_str(l).ok()));
    }
    out
}

/// The memory's lines about a1 (`[a1] ...`): what the Chief was told.
fn told_about_a1(h: &Harness) -> Vec<String> {
    h.log()
        .into_iter()
        .map(|(_, t)| t)
        .filter(|t| t.starts_with("[a1]"))
        .collect()
}

/// acpmux refused a1's cancel: its turn goes on, so "Stop all agents"
/// reports it in `errors`, never as stopped, and a1 stays as it was, so
/// Restart leaves it alone.
#[test]
fn a_refused_cancel_on_stop_all_is_an_error_not_a_stop() {
    let mut h = Harness::new(default_script());
    a1_at_work(&mut h);
    h.agents
        .inner
        .lock()
        .unwrap()
        .cancel_errors_once
        .push_back("acpmux: the turn is busy".into());

    let answer = stop_all(&mut h);
    assert_eq!(answer["subagents"], json!([]), "{answer}");
    let errors = answer["errors"].as_array().cloned().unwrap_or_default();
    assert_eq!(errors.len(), 1, "{answer}");
    assert!(errors[0].as_str().unwrap().starts_with("a1"), "{answer}");
    let a1 = sub(&h, "a1");
    assert!(!a1.cancelled, "a1 was not stopped");
    assert_eq!(a1.status, SubStatus::Running);

    let again = restart(&mut h, &["a1"]);
    assert_eq!(again["restarted"], json!([]), "{again}");
}

/// Restart sends a stopped a1 its continue through a fresh cancel of its
/// ending turn. When acpmux refuses that cancel, a1 is reported in
/// `errors` and stays stopped (cancelled), so a later Restart still brings
/// it back.
#[test]
fn a_refused_cancel_on_restart_keeps_the_subagent_stopped() {
    let mut h = Harness::new(default_script());
    a1_at_work(&mut h);
    let stopped = stop_all(&mut h);
    assert_eq!(stopped["subagents"], json!(["a1"]), "{stopped}");
    assert!(sub(&h, "a1").cancelled);
    h.agents
        .inner
        .lock()
        .unwrap()
        .cancel_errors_once
        .push_back("acpmux: the turn is busy".into());

    let answer = restart(&mut h, &["a1"]);
    assert_eq!(answer["restarted"], json!([]), "{answer}");
    let errors = answer["errors"].as_array().cloned().unwrap_or_default();
    assert_eq!(errors.len(), 1, "{answer}");
    assert!(errors[0].as_str().unwrap().starts_with("a1"), "{answer}");
    assert!(sub(&h, "a1").cancelled, "a1 is still stopped");

    // acpmux takes the cancel now: Restart brings a1 back.
    let later = restart(&mut h, &["a1"]);
    assert_eq!(later["restarted"], json!(["a1"]), "{later}");
    assert!(!sub(&h, "a1").cancelled);
}

/// "Stop all agents" while a1 is still starting: a1 is named (with a note
/// that it stops as it starts), and its turn is cancelled as soon as its
/// task is sent.
#[test]
fn stop_all_stops_a_subagent_that_is_still_starting() {
    let mut h = Harness::new(default_script());
    let worker = a1_starting(&mut h);

    let answer = stop_all(&mut h);
    assert_eq!(answer["subagents"], json!(["a1"]), "{answer}");
    let note = answer["note"].as_str().unwrap_or_default();
    assert!(
        note.contains("a1") && note.contains("still starting"),
        "{answer}"
    );

    assert!(pump(&mut h, worker).unwrap().contains("Started a1"));
    let a1 = sub(&h, "a1");
    let session = a1.session_id.clone().expect("a1's session");
    assert!(a1.cancelled, "a1 stays stopped");
    let inner = h.agents.inner.lock().unwrap();
    assert!(
        inner.cancels.contains(&session),
        "a1's turn is cancelled as it starts: {:?}",
        inner.cancels
    );
    assert!(
        inner.killed_processes.contains(&session),
        "with its background processes"
    );
}

/// Restart on the toast before a stopped starting a1 has its session: it
/// just goes on as it starts (one session, never queued and started
/// twice), and nothing cancels it.
#[test]
fn restart_of_a_subagent_stopped_while_starting_lets_it_start() {
    let mut h = Harness::new(default_script());
    let worker = a1_starting(&mut h);
    let stopped = stop_all(&mut h);
    assert_eq!(stopped["subagents"], json!(["a1"]), "{stopped}");

    let answer = restart(&mut h, &["a1"]);
    assert_eq!(answer["restarted"], json!(["a1"]), "{answer}");

    assert!(pump(&mut h, worker).unwrap().contains("Started a1"));
    let a1 = sub(&h, "a1");
    assert!(!a1.cancelled);
    assert_eq!(a1.status, SubStatus::Running);
    let inner = h.agents.inner.lock().unwrap();
    assert!(inner.cancels.is_empty(), "{:?}", inner.cancels);
    let sessions = inner
        .specs
        .iter()
        .filter(|s| s.tags.contains_key("optchat.subagent"))
        .count();
    assert_eq!(sessions, 1, "a1 started once");
}

/// What a1 was told stays with it when acpmux refuses its cancel: the
/// message an earlier interrupt left for after its turn (`after_stop`) and
/// a tell waiting in its inbox while it is paused.
#[test]
fn a_refused_cancel_on_stop_all_keeps_what_the_subagent_was_told() {
    let mut h = Harness::new(default_script());
    a1_at_work(&mut h);
    let call = |action: &str, message: Option<&str>| ControlCall {
        action: action.into(),
        id: Some("a1".into()),
        message: message.map(str::to_owned),
        ..ControlCall::default()
    };
    // The interrupt's and the pause's cancels reach nothing: a1's turn goes
    // on, the interrupt's message waits for its end, a tell waits in its
    // inbox for its resume.
    h.agents.inner.lock().unwrap().ignore_cancels = 2;
    let (a, interrupt) = (
        spawner(&h),
        call("interrupt", Some("use the staging branch")),
    );
    let interrupted = pump(&mut h, std::thread::spawn(move || a.control(interrupt))).unwrap();
    assert!(interrupted.starts_with("outcome: done."), "{interrupted}");
    let (a, pause) = (spawner(&h), call("pause", None));
    let paused = pump(&mut h, std::thread::spawn(move || a.control(pause))).unwrap();
    assert!(paused.starts_with("outcome: done."), "{paused}");
    let a = spawner(&h);
    let told = pump(
        &mut h,
        std::thread::spawn(move || a.tell("a1", "and run the tests")),
    )
    .unwrap();
    assert!(told.starts_with("outcome: queued."), "{told}");
    let before = sub(&h, "a1");
    assert_eq!(before.status, SubStatus::Running);
    let after_stop = before.after_stop.clone().expect("a1's message waits");
    let inbox: Vec<String> = before.inbox.iter().map(|m| m.text.clone()).collect();
    assert_eq!(inbox, vec!["and run the tests".to_owned()]);
    h.agents
        .inner
        .lock()
        .unwrap()
        .cancel_errors_once
        .push_back("acpmux: the turn is busy".into());

    let answer = stop_all(&mut h);
    assert_eq!(answer["subagents"], json!([]), "{answer}");
    let a1 = sub(&h, "a1");
    assert_eq!(a1.after_stop, Some(after_stop), "a1 keeps its message");
    let kept: Vec<String> = a1.inbox.iter().map(|m| m.text.clone()).collect();
    assert_eq!(kept, inbox, "a1 keeps its inbox");
    assert!(!a1.cancelled);
}

/// Restart after a1 was stopped between its session and its task: it just
/// goes on as its task is sent. No second cancel cuts its task turn, and
/// no "continue" waits for that turn's end.
#[test]
fn restart_of_a_subagent_stopped_before_its_task_sends_no_cancel() {
    let mut h = Harness::new(default_script());
    let worker = a1_before_its_task(&mut h);
    // No turn yet: the stop's cancel reaches nothing.
    h.agents.inner.lock().unwrap().ignore_cancels = 1;
    let stopped = stop_all(&mut h);
    assert_eq!(stopped["subagents"], json!(["a1"]), "{stopped}");
    let cancels = h.agents.inner.lock().unwrap().cancels.len();

    let answer = restart(&mut h, &["a1"]);
    assert_eq!(answer["restarted"], json!(["a1"]), "{answer}");
    assert!(pump(&mut h, worker).unwrap().contains("Started a1"));
    let a1 = sub(&h, "a1");
    assert!(!a1.cancelled);
    assert!(a1.after_stop.is_none(), "nothing waits to cut its task");
    assert_eq!(a1.status, SubStatus::Running);
    assert_eq!(
        h.agents.inner.lock().unwrap().cancels.len(),
        cancels,
        "no cancel after the stop's own"
    );
}

/// a1 is stopped while starting, and the cancel sent with its prompt
/// reaches acpmux before the prompt does, so acpmux drops it. When a1's
/// task turn really starts, a1 is cancelled again: its task never runs on
/// after "Stop all agents" said it stopped.
#[test]
fn a_cancel_lost_before_the_prompt_is_sent_again_as_the_task_turn_starts() {
    let mut h = Harness::new(quiet_script());
    let worker = a1_starting(&mut h);
    let answer = stop_all(&mut h);
    assert_eq!(answer["subagents"], json!(["a1"]), "{answer}");
    // The cancel sent as its prompt goes out beats the prompt: lost.
    h.agents.inner.lock().unwrap().ignore_cancels = 1;
    assert!(pump(&mut h, worker).unwrap().contains("Started a1"));
    let session = sub(&h, "a1").session_id.expect("a1's session");
    assert_eq!(cancels(&h), vec![session.clone()], "the early cancel");

    task_turn_starts(&h, &session);
    step_until(&mut h, "a1's task turn is cancelled as it starts", |h| {
        cancels(h).len() == 2
    });
    assert_eq!(cancels(&h), vec![session.clone(), session.clone()]);
    assert!(sub(&h, "a1").cancelled, "a1 stays stopped");
    let killed = h.agents.inner.lock().unwrap().killed_processes.clone();
    assert!(killed.contains(&session), "with its background processes");
}

/// Restart on the toast after a1's early cancel was lost and before its
/// task turn starts: a1 goes on, so the stale stop never cuts the turn
/// that then starts.
#[test]
fn a_restart_before_the_task_turn_starts_sends_no_cancel_as_it_starts() {
    let mut h = Harness::new(quiet_script());
    h.brain
        .set_trace(Trace::open(&h.dir.path().join("traces"), false).unwrap());
    let worker = a1_starting(&mut h);
    let stopped = stop_all(&mut h);
    assert_eq!(stopped["subagents"], json!(["a1"]), "{stopped}");
    // The cancel sent with its prompt and Restart's own reach nothing.
    h.agents.inner.lock().unwrap().ignore_cancels = 2;
    assert!(pump(&mut h, worker).unwrap().contains("Started a1"));
    let restarted = restart(&mut h, &["a1"]);
    assert_eq!(restarted["restarted"], json!(["a1"]), "{restarted}");
    assert!(!sub(&h, "a1").cancelled);
    let before = cancels(&h).len();

    let session = sub(&h, "a1").session_id.expect("a1's session");
    task_turn_starts(&h, &session);
    step_until(&mut h, "the brain sees a1's task turn start", |h| {
        traces(h)
            .iter()
            .any(|t| t["ev"] == "subagent.turn_started" && t["id"] == "a1")
    });
    assert_eq!(cancels(&h).len(), before, "no cancel cuts its task turn");
    assert!(!sub(&h, "a1").cancelled);
}

/// acpmux refuses the cancel sent as a1's task turn starts: a1 goes on
/// with its task, and the Chief is told (the stop-all toast already said
/// it stopped), as a refused cancel is reported in the stop-all answer.
#[test]
fn a_refused_cancel_as_the_task_turn_starts_is_told_to_the_chief() {
    let mut h = Harness::new(quiet_script());
    h.connect();
    let worker = a1_starting(&mut h);
    let answer = stop_all(&mut h);
    assert_eq!(answer["subagents"], json!(["a1"]), "{answer}");
    h.agents.inner.lock().unwrap().ignore_cancels = 1;
    assert!(pump(&mut h, worker).unwrap().contains("Started a1"));
    assert!(told_about_a1(&h).is_empty(), "{:?}", h.log());
    h.agents
        .inner
        .lock()
        .unwrap()
        .cancel_errors_once
        .push_back("acpmux: the turn is busy".into());

    let session = sub(&h, "a1").session_id.expect("a1's session");
    task_turn_starts(&h, &session);
    step_until(&mut h, "the Chief is told a1 did not stop", |h| {
        !told_about_a1(h).is_empty()
    });
    let told = told_about_a1(&h).join("\n");
    assert!(told.contains("did not stop"), "{told}");
    assert!(told.contains("acpmux: the turn is busy"), "{told}");
    let a1 = sub(&h, "a1");
    assert!(!a1.cancelled, "a1 goes on");
    assert_eq!(a1.status, SubStatus::Running);
}

/// acpmux refuses the cancel sent as soon as a1's task is sent: a1 goes on
/// with its task, and the Chief is told.
#[test]
fn a_refused_cancel_as_the_task_is_sent_is_told_to_the_chief() {
    let mut h = Harness::new(default_script());
    h.connect();
    let worker = a1_starting(&mut h);
    let answer = stop_all(&mut h);
    assert_eq!(answer["subagents"], json!(["a1"]), "{answer}");
    h.agents
        .inner
        .lock()
        .unwrap()
        .cancel_errors_once
        .push_back("acpmux: the turn is busy".into());

    assert!(pump(&mut h, worker).unwrap().contains("Started a1"));
    step_until(&mut h, "the Chief is told a1 did not stop", |h| {
        !told_about_a1(h).is_empty()
    });
    let told = told_about_a1(&h).join("\n");
    assert!(told.contains("did not stop"), "{told}");
    assert!(told.contains("acpmux: the turn is busy"), "{told}");
    let a1 = sub(&h, "a1");
    assert!(!a1.cancelled, "a1 goes on");
    assert_eq!(a1.status, SubStatus::Running);
}
