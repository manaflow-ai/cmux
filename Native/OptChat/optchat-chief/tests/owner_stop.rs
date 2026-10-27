//! chief.stop: a turn the owner stopped posts nothing to the conversation
//! (and so to no bridge), however it ends. The owner pressed stop and
//! already knows (Lawrence 2026-10-19).

mod common;

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::Duration;

use cmux_conversation::Op;
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::state::{HostState, StateFile, SubStatus};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::json;

/// chief.stop, as the host's control socket sends it.
fn owner_stop(h: &mut Harness) {
    let (reply, answer) = channel();
    h.brain.step(Input::Stop { reply });
    let answer = answer.try_recv().expect("chief.stop answers at once");
    assert_eq!(answer["stopped"], true, "{answer}");
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

/// Nothing reached the conversation: no reply, no done marker.
fn assert_no_post(h: &Harness) {
    let owner = h.owner.lock().unwrap();
    let posts: Vec<_> = owner
        .ops
        .iter()
        .filter(|(_, op)| matches!(op, Op::MessageSend { .. }))
        .collect();
    assert!(posts.is_empty(), "nothing posted: {posts:?}");
}

#[test]
fn a_stopped_turn_that_finishes_before_the_interrupt_posts_nothing() {
    let mut h = Harness::new(default_script());
    running(&mut h, "hi");
    // The agent never sees the cancel: its turn ends normally, with a reply.
    h.agents.inner.lock().unwrap().ignore_cancels = usize::MAX;
    owner_stop(&mut h);
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    assert_no_post(&h);
}

#[test]
fn a_stopped_turn_that_closes_open_work_posts_no_done_marker() {
    // An earlier reply left msg_1's work open (a subagent was at work); the
    // turn now running answers msg_1 and so would close it.
    let dir = tempfile::tempdir().unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            open_answers: vec!["msg_1".into()],
            ..Default::default()
        })
        .unwrap();
    let owner = std::sync::Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    running(&mut h, "how did it go?");
    owner_stop(&mut h);
    h.agents.hold(false);
    h.settle_posts();
    assert_no_post(&h);
    // With no done marker, msg_1's work stays open for a later turn to
    // close: a client's pending mark must not stick forever.
    let rows = h.chat.state_prefix("host/").unwrap();
    assert!(
        rows.iter()
            .any(|(k, v)| k == "host/open_answers" && v.contains("msg_1")),
        "{rows:?}"
    );
}

/// 2026-10-20: after the owner stopped a19, a background shell its run had
/// started (Claude Code's run_in_background, which acpmux tracks and lets
/// outlive the turn) still ran `git fetch` in the shared checkout. The
/// owner's stop of a subagent (chief.stop {name}) ends its background
/// processes too.
#[test]
fn owner_stop_ends_the_background_processes_of_the_subagents_it_stops() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    let spawner = Arc::new(Spawner::new(
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
    ));
    let worker = std::thread::spawn(move || spawner.spawn(vec!["watch the build".into()], None));
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    assert!(worker.join().unwrap().unwrap().contains("Started a1"));
    let session = {
        let inner = h.agents.inner.lock().unwrap();
        let k = inner
            .specs
            .iter()
            .position(|s| s.tags.contains_key("optchat.subagent"))
            .expect("a1's session");
        format!("s{}", k + 1)
    };
    let (reply, answer) = channel();
    h.brain.step(Input::StopSubagent {
        name: "a1".into(),
        reply,
    });
    let answer = answer
        .try_recv()
        .expect("chief.stop {name} answers at once");
    assert_eq!(answer["stopped"], true, "{answer}");
    let inner = h.agents.inner.lock().unwrap();
    assert!(inner.cancels.contains(&session), "{:?}", inner.cancels);
    assert_eq!(inner.killed_processes, vec![session]);
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
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
    worker.join().unwrap()
}

fn status(h: &Harness, id: &str) -> SubStatus {
    h.brain.state().sub(id).expect(id).1.status
}

/// The Home stop button (or Esc) while the Chief works sends chief.stop:
/// it stops the Chief's turn only. Every subagent at work goes on; only its
/// own stop or a cancel stops it (host.log 2026-10-20: "the owner stopped
/// subagents a51, a60, a62, ..." ~48 times after Home messages).
#[test]
fn chief_stop_leaves_subagents_at_work_running() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["build the thing".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    assert_eq!(status(&h, "a1"), SubStatus::Running);
    let before = h.agents.inner.lock().unwrap().cancels.clone();

    let (reply, answer) = channel();
    h.brain.step(Input::Stop { reply });
    let answer = answer.try_recv().expect("chief.stop answers at once");
    assert!(answer.get("subagents").is_none(), "{answer}");
    assert_eq!(status(&h, "a1"), SubStatus::Running, "a1 goes on");
    assert_eq!(
        h.agents.inner.lock().unwrap().cancels,
        before,
        "no subagent session was cancelled"
    );
}

/// A subagent the user stopped is no longer at work, even when its session
/// never ends its turn: it frees its slot at once (#7: a51, a60, a62 stayed
/// "at work" after their stop).
#[test]
fn a_stopped_subagent_frees_its_slot_even_when_its_turn_never_ends() {
    let mut h = Harness::new(default_script());
    h.brain.set_max_live(Some(1));
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["one".into(), "two".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("a2: queued"), "{spawned}");
    // The agent never sees the cancel: a1's turn never ends.
    h.agents.inner.lock().unwrap().ignore_cancels = usize::MAX;
    let (reply, answer) = channel();
    h.brain.step(Input::StopSubagent {
        name: "a1".into(),
        reply,
    });
    let answer = answer
        .try_recv()
        .expect("chief.stop {name} answers at once");
    assert_eq!(answer["stopped"], true, "{answer}");
    run(&mut h, || ());
    assert_ne!(status(&h, "a2"), SubStatus::Queued, "a2 got a1's slot");
}

/// "Stop all agents" (the menu item, or Option-Stop) as the host's control
/// socket sends it: chief.stop {all: true}.
fn stop_all(h: &mut Harness) -> serde_json::Value {
    let (reply, answer) = channel();
    h.brain.step(Input::StopAll { reply });
    answer.try_recv().expect("chief.stop {all} answers at once")
}

/// The coordinator 2026-10-20: a plain Stop ends only the Chief's turn;
/// "Stop all agents" is its own explicit action. It stops the turn and
/// every subagent at work or queued, ends their background processes, and
/// names them so the undo toast can list them and offer Restart.
#[test]
fn stop_all_stops_every_subagent_and_names_them() {
    let mut h = Harness::new(default_script());
    h.brain.set_max_live(Some(1));
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["one".into(), "two".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("a2: queued"), "{spawned}");
    assert_eq!(status(&h, "a1"), SubStatus::Running);

    let answer = stop_all(&mut h);
    assert_eq!(
        answer["subagents"],
        serde_json::json!(["a1", "a2"]),
        "{answer}"
    );
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.cancels.len(), 1, "a1's turn is cancelled");
    assert_eq!(
        inner.killed_processes, inner.cancels,
        "with its background processes"
    );
    drop(inner);
    assert_ne!(status(&h, "a2"), SubStatus::Queued, "a2 never starts");
}

/// Restart on the undo toast brings back what "Stop all agents" stopped:
/// each one goes on (a started one in its own session, told to continue; a
/// queued one queued again with its task).
#[test]
fn restart_brings_back_the_subagents_stop_all_stopped() {
    let mut h = Harness::new(default_script());
    h.brain.set_max_live(Some(1));
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["one".into(), "two".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("a2: queued"), "{spawned}");
    let stopped = stop_all(&mut h);
    let names: Vec<String> = serde_json::from_value(stopped["subagents"].clone()).unwrap();
    // a1's cancelled turn ends: acpmux reports its session idle.
    let a1_session = h
        .brain
        .state()
        .sub("a1")
        .and_then(|(_, s)| s.session_id.clone())
        .expect("a1's session");
    h.brain.step(Input::from(AgentEvent::SessionChanged(
        serde_json::from_value(serde_json::json!({
            "sessionId": a1_session, "name": "a1", "status": "idle", "harness": "claude",
        }))
        .unwrap(),
    )));
    run(&mut h, || ());
    let prompts_before = h.agents.inner.lock().unwrap().prompts.len();

    let (reply, answer) = channel();
    h.brain.step(Input::RestartSubagents { names, reply });
    let answer = answer
        .try_recv()
        .expect("chief.stop {restart} answers at once");
    assert_eq!(
        answer["restarted"],
        serde_json::json!(["a1", "a2"]),
        "{answer}"
    );
    run(&mut h, || ());
    for id in ["a1", "a2"] {
        let sub = h.brain.state().sub(id).expect(id).1.clone();
        assert!(!sub.cancelled, "{id} is no longer cancelled");
        assert!(
            matches!(
                sub.status,
                SubStatus::Queued | SubStatus::Starting | SubStatus::Running
            ),
            "{id} is at work or queued again: {:?}",
            sub.status
        );
    }
    let told = h.agents.inner.lock().unwrap().prompts[prompts_before..]
        .iter()
        .any(|blocks| {
            serde_json::to_string(blocks)
                .unwrap()
                .contains("Continue from where you stopped")
        });
    assert!(told, "a1 is told to continue in its own session");

    // A second Restart (the toast pressed twice) leaves them as they are.
    let (reply, answer) = channel();
    h.brain.step(Input::RestartSubagents {
        names: vec!["a1".into(), "a2".into()],
        reply,
    });
    let again = answer.try_recv().expect("answers at once");
    assert_eq!(again["restarted"], serde_json::json!([]), "{again}");
}

/// The subagent's turn ("build the thing") never ends; the Chief's turn ends
/// with `chief_reply`, or never ends when it is None.
fn chief_and_endless_subagent(chief_reply: Option<&'static str>) -> Script {
    Box::new(move |_, blocks| {
        let started = json!({"dir": "mux", "kind": "turn_started", "msg": {}});
        if serde_json::to_string(blocks)
            .unwrap()
            .contains("build the thing")
        {
            return vec![started];
        }
        let Some(text) = chief_reply else {
            return vec![started];
        };
        vec![
            started,
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": text}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

/// a1 is at work (its session made); returns its session.
fn a1_at_work(h: &mut Harness) -> String {
    h.connect();
    // a1's turn never answers: it stays at work.
    h.agents.inner.lock().unwrap().answer_never = true;
    let sp = spawner(h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let spawned = run(h, move || sp.spawn(vec!["build the thing".into()], None)).unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    assert_eq!(status(h, "a1"), SubStatus::Running);
    h.brain
        .state()
        .sub("a1")
        .unwrap()
        .1
        .session_id
        .clone()
        .expect("a1 has a session")
}

/// The Chief ending its own turn with its `stop` tool never stops a
/// subagent (2026-10-20: every turn the Chief ended with stop() stopped all
/// subagents "by the user" seconds after they resumed).
#[test]
fn the_chiefs_stop_tool_leaves_subagents_at_work_running() {
    let mut h = Harness::new(chief_and_endless_subagent(None));
    let session = a1_at_work(&mut h);
    let prompts = h.agents.inner.lock().unwrap().prompts.len();
    h.agents.hold(true);
    h.say("user_local", "start the work");
    while h.agents.inner.lock().unwrap().prompts.len() <= prompts {
        h.step();
    }
    // A person's message gets words before stop (eval_replies.rs).
    let sp = spawner(&h);
    run(&mut h, move || {
        sp.send(optchat_chief::tools::SendCall {
            sign_in: None,
            text: Some("On it.".into()),
            attachments: Vec::new(),
            reply_to: None,
        })
    })
    .expect("send answers");
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.stop_turn()).expect("stop answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    h.agents.hold(false);
    h.settle_posts();
    assert_eq!(status(&h, "a1"), SubStatus::Running, "a1 goes on");
    let cancels = h.agents.inner.lock().unwrap().cancels.clone();
    assert!(!cancels.contains(&session), "a1 not cancelled: {cancels:?}");
}

/// A Chief turn that ends with NO_REPLY (posts nothing) never stops a
/// subagent either.
#[test]
fn a_no_reply_turn_end_leaves_subagents_at_work_running() {
    let mut h = Harness::new(chief_and_endless_subagent(Some(
        optchat_chief::membership::NO_REPLY,
    )));
    let session = a1_at_work(&mut h);
    h.say("user_local", "anything new?");
    h.settle_posts();
    assert_eq!(status(&h, "a1"), SubStatus::Running, "a1 goes on");
    let cancels = h.agents.inner.lock().unwrap().cancels.clone();
    assert!(!cancels.contains(&session), "a1 not cancelled: {cancels:?}");
}
