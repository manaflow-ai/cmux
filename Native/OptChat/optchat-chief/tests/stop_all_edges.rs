//! chief.stop {all} and {restart} at their edges (#22978's follow-ups): a
//! cancel acpmux refuses stops nothing, so it is reported as an error and
//! the subagent stays as it was; a subagent still starting when "Stop all
//! agents" comes is named and stopped as soon as its task is sent.

mod common;

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::Duration;

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::state::{SubRecord, SubStatus};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{ControlCall, Orchestrator};
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
