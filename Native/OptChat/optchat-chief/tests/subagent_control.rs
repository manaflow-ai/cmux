//! Native subagent control (DESIGN 2026-10-19): `tell` never fails for a
//! known subagent (a82: "I tried to add this to a82's job twice, but it's
//! still waiting to start"), and `control` answers every call with a clear
//! outcome that a repeat turns into a noop.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{ControlCall, Orchestrator};

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

/// Runs `f` on its own thread while the brain takes its inputs; then lets
/// the brain take what is left.
fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    settle(h);
    worker.join().unwrap()
}

fn settle(h: &mut Harness) {
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
}

/// The text of every prompt sent to a subagent session, in order.
fn sub_prompts(h: &Harness) -> Vec<String> {
    let inner = h.agents.inner.lock().unwrap();
    let subs: Vec<String> = inner
        .specs
        .iter()
        .enumerate()
        .filter(|(_, s)| s.tags.contains_key("optchat.subagent"))
        .map(|(k, _)| format!("s{}", k + 1))
        .collect();
    inner
        .prompts
        .iter()
        .zip(&inner.prompt_sessions)
        .filter(|(_, s)| subs.contains(s))
        .map(|(blocks, _)| serde_json::to_string(blocks).unwrap())
        .collect()
}

fn wait_for(h: &mut Harness, what: impl Fn(&Harness) -> bool) {
    let until = Instant::now() + Duration::from_secs(5);
    while !what(h) && Instant::now() < until {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    assert!(what(h), "timed out");
}

#[test]
fn a_tell_to_a_starting_subagent_waits_and_follows_its_task() {
    let mut h = Harness::new(default_script());
    h.agents.inner.lock().unwrap().slow_session =
        Some(("optchat-sub".into(), Duration::from_millis(400)));
    let sp = spawner(&h);
    let (a, b) = (sp.clone(), sp.clone());
    let answers = run(&mut h, move || {
        let spawn = std::thread::spawn(move || a.spawn(vec!["say hello".into()], None));
        std::thread::sleep(Duration::from_millis(150));
        let first = b.tell("a1", "also count to three");
        let second = b.tell("a1", "and then stop");
        (spawn.join().unwrap(), first, second)
    });
    assert!(answers.0.unwrap().contains("Started a1"));
    let first = answers
        .1
        .expect("a tell to a starting subagent never fails");
    assert!(first.starts_with("outcome: queued."), "{first}");
    assert!(answers.2.unwrap().contains("2 waiting"));
    wait_for(&mut h, |h| sub_prompts(h).len() >= 2);
    let prompts = sub_prompts(&h);
    assert!(prompts[0].contains("say hello"), "{prompts:?}");
    let later = prompts[1..].join("\n");
    let (one, two) = (
        later
            .find("also count to three")
            .expect("first message delivered"),
        later
            .find("and then stop")
            .expect("second message delivered"),
    );
    assert!(one < two, "in order: {later}");
}

#[test]
fn a_queued_subagent_gets_its_messages_with_its_task_when_the_cap_rises() {
    let mut h = Harness::new(default_script());
    h.brain.set_max_live(Some(1));
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["task one".into(), "task two".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("a2: queued"), "{spawned}");
    let a = sp.clone();
    let told = run(&mut h, move || a.tell("a2", "use the staging branch")).unwrap();
    assert!(told.starts_with("outcome: queued."), "{told}");
    assert!(told.contains("with its task"), "{told}");
    let a = sp.clone();
    let cap = run(&mut h, move || {
        a.control(ControlCall {
            action: "cap".into(),
            n: Some(0),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(cap.starts_with("outcome: done."), "{cap}");
    wait_for(&mut h, |h| sub_prompts(h).len() >= 2);
    let second = &sub_prompts(&h)[1];
    assert!(second.contains("task two"), "{second}");
    assert!(second.contains("use the staging branch"), "{second}");
    // The same cap again changes nothing.
    let a = sp.clone();
    let again = run(&mut h, move || {
        a.control(ControlCall {
            action: "cap".into(),
            n: Some(0),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(again.starts_with("outcome: noop."), "{again}");
}

/// 2026-10-20 the user: "we need to remove 40 agent limit by default".
/// With no env cap and no `control cap`, 48 subagents (more than the old
/// 40) all start at once: none waits.
#[test]
fn with_no_cap_set_every_spawn_starts_at_once() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    for batch in 0..6 {
        let a = sp.clone();
        let tasks: Vec<String> = (0..8).map(|i| format!("task {batch}-{i}")).collect();
        let spawned = run(&mut h, move || a.spawn(tasks, None)).unwrap();
        assert!(!spawned.contains("queued"), "{spawned}");
    }
    let a = sp.clone();
    let status = run(&mut h, move || {
        a.control(ControlCall {
            action: "status".into(),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(status.contains("(no cap)"), "{status}");
}

/// A cap set with `control cap` (2026-10-20: the Chief set 40 and the
/// queued line blamed OPTCHAT_MAX_LIVE_SUBAGENTS, so the user saw a limit
/// with no visible source): the queued line names `control cap` and says
/// how to lift it.
#[test]
fn a_queued_line_names_the_control_cap_and_how_to_lift_it() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let cap = run(&mut h, move || {
        a.control(ControlCall {
            action: "cap".into(),
            n: Some(1),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(cap.starts_with("outcome: done."), "{cap}");
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["task one".into(), "task two".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("a2: queued"), "{spawned}");
    assert!(spawned.contains("control cap 1"), "{spawned}");
    assert!(spawned.contains("control cap 0"), "{spawned}");
    assert!(!spawned.contains("OPTCHAT_MAX_LIVE_SUBAGENTS"), "{spawned}");
}

/// A cap from the env: the queued line names the env and how to lift it.
#[test]
fn a_queued_line_names_the_env_cap() {
    let mut h = Harness::new(default_script());
    h.brain.set_max_live(Some(1));
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["task one".into(), "task two".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("a2: queued"), "{spawned}");
    assert!(
        spawned.contains("OPTCHAT_MAX_LIVE_SUBAGENTS=1"),
        "{spawned}"
    );
    assert!(spawned.contains("control cap 0"), "{spawned}");
}

/// The session id of the first subagent (`a1`).
fn sub_session(h: &Harness) -> String {
    let inner = h.agents.inner.lock().unwrap();
    let k = inner
        .specs
        .iter()
        .position(|s| s.tags.contains_key("optchat.subagent"))
        .expect("a subagent session");
    format!("s{}", k + 1)
}

fn idle(session: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(serde_json::json!({
        "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
    }))
    .unwrap()
}

/// Tell interrupts by default (user 2026-10-20: "We need a default behavior
/// for you to interrupt instead of queuing."): a running subagent whose
/// agent cannot steer has its turn stopped, and the message is its next
/// prompt, not one queued behind an hour-long turn.
#[test]
fn a_tell_to_a_running_subagent_that_cannot_steer_interrupts_it() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["long job".into()], None)).unwrap();
    wait_for(&mut h, |h| !sub_prompts(h).is_empty());
    let session = sub_session(&h);
    let a = sp.clone();
    let told = run(&mut h, move || a.tell("a1", "stop and fix the build")).unwrap();
    assert!(told.starts_with("outcome: done."), "{told}");
    wait_for(&mut h, |h| {
        !h.agents.inner.lock().unwrap().cancels.is_empty()
    });
    assert_eq!(
        h.agents.inner.lock().unwrap().cancels,
        vec![session.clone()]
    );
    // Nothing waits in the queue behind the running turn.
    assert_eq!(sub_prompts(&h).len(), 1, "{:?}", sub_prompts(&h));
    // The cut turn ends: the message goes in as the next prompt.
    h.agents.hold(false);
    h.brain.step(Input::from(
        optchat_chief::acpmux::AgentEvent::SessionChanged(idle(&session)),
    ));
    wait_for(&mut h, |h| sub_prompts(h).len() >= 2);
    let prompts = sub_prompts(&h);
    assert!(prompts[1].contains("stop and fix the build"), "{prompts:?}");
}

/// `queue: true` keeps the old behavior for a low-priority FYI: no
/// interrupt, the message waits after the running turn.
#[test]
fn a_queue_tell_waits_for_the_turn() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["long job".into()], None)).unwrap();
    wait_for(&mut h, |h| !sub_prompts(h).is_empty());
    let a = sp.clone();
    let told = run(&mut h, move || {
        a.tell_with("a1", "FYI: a188 landed its fix", None, true)
    })
    .unwrap();
    assert!(told.starts_with("outcome: done."), "{told}");
    wait_for(&mut h, |h| sub_prompts(h).len() >= 2);
    assert!(sub_prompts(&h)[1].contains("FYI: a188 landed its fix"));
    let inner = h.agents.inner.lock().unwrap();
    assert!(inner.cancels.is_empty(), "{:?}", inner.cancels);
    assert!(
        inner.prompt_ids[1].starts_with("optchat-fyi:a1:"),
        "{:?}",
        inner.prompt_ids
    );
}

/// Flush on the change: Chief tells an older host left in a running
/// subagent's acpmux queue are taken out on reconnect and sent again as one
/// interrupting tell; a `queue` (fyi) one stays queued.
#[test]
fn queued_chief_tells_are_flushed_as_an_interrupt_on_reconnect() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["long job".into()], None)).unwrap();
    wait_for(&mut h, |h| !sub_prompts(h).is_empty());
    let session = sub_session(&h);
    h.agents.append_events(
        &session,
        vec![
            serde_json::json!({"dir": "mux", "kind": "queued", "msg": {"text": "From a162: rebase first", "promptId": "optchat-tell:a1:1"}}),
            serde_json::json!({"dir": "mux", "kind": "queued", "msg": {"text": "already ran", "promptId": "optchat-tell:a1:2"}}),
            serde_json::json!({"dir": "mux", "kind": "user_message", "msg": {"text": "already ran", "promptId": "optchat-tell:a1:2"}}),
            serde_json::json!({"dir": "mux", "kind": "queued", "msg": {"text": "low priority", "promptId": "optchat-fyi:a1:3"}}),
        ],
    );
    let running: cmux_chief::acp::SessionSummary = serde_json::from_value(serde_json::json!({
        "sessionId": session, "name": "a1", "status": "running", "harness": "claude",
    }))
    .unwrap();
    h.brain
        .step(Input::from(optchat_chief::acpmux::AgentEvent::Up(vec![
            running,
        ])));
    wait_for(&mut h, |h| {
        !h.agents.inner.lock().unwrap().cancels.is_empty()
    });
    assert_eq!(
        h.agents.inner.lock().unwrap().removed_queued,
        vec![(session.clone(), "optchat-tell:a1:1".to_owned())]
    );
    h.agents.hold(false);
    h.brain.step(Input::from(
        optchat_chief::acpmux::AgentEvent::SessionChanged(idle(&session)),
    ));
    wait_for(&mut h, |h| sub_prompts(h).len() >= 2);
    let prompts = sub_prompts(&h);
    assert!(
        prompts[1].contains("From a162: rebase first"),
        "{prompts:?}"
    );
    assert!(!prompts[1].contains("low priority"), "{prompts:?}");
}

/// acp-chief-issues.md #10: a tell to a running subagent whose steer is
/// refused (acpmux: "the session has no running turn that its agent can
/// steer", 25 times on 2026-10-19) interrupts the turn and goes as its next
/// prompt; when that prompt fails, the message was only logged and lost. It
/// must stay in the subagent's inbox and go with a later prompt.
#[test]
fn a_tell_whose_steer_and_prompt_both_fail_is_kept_and_delivered_later() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    let a = sp.clone();
    let spawned = run(&mut h, move || a.spawn(vec!["long task".into()], None)).unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    wait_for(&mut h, |h| !sub_prompts(h).is_empty());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.steering = false;
        inner
            .prompt_errors_once
            .push_back("session/prompt: agent process closed".into());
    }
    let a = sp.clone();
    let told = run(&mut h, move || a.tell("a1", "use the staging branch")).unwrap();
    assert!(told.starts_with("outcome:"), "{told}");
    settle(&mut h);
    // Its turn ends (acpmux reports its session idle): the kept message is
    // its next prompt.
    h.agents.release();
    std::thread::sleep(Duration::from_millis(100));
    let session = h
        .brain
        .state()
        .sub("a1")
        .and_then(|(_, s)| s.session_id.clone())
        .expect("a1 has a session");
    let idle: cmux_chief::acp::SessionSummary = serde_json::from_value(serde_json::json!({
        "sessionId": session, "name": "optchat-sub-h0me-a1", "status": "idle", "harness": "claude",
    }))
    .unwrap();
    h.brain.step(optchat_chief::brain::Input::from(
        optchat_chief::acpmux::AgentEvent::SessionChanged(idle),
    ));
    wait_for(&mut h, |h| {
        sub_prompts(h)
            .iter()
            .skip(1)
            .any(|p| p.contains("use the staging branch"))
    });
}

#[test]
fn keyed_tells_and_cancels_are_idempotent() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["long job".into()], None)).unwrap();
    wait_for(&mut h, |h| !sub_prompts(h).is_empty());
    let a = sp.clone();
    let (one, two) = run(&mut h, move || {
        (
            // queue: these check the key, not the interrupt.
            a.tell_with("a1", "focus on tests", Some("k1"), true),
            a.tell_with("a1", "focus on tests", Some("k1"), true),
        )
    });
    assert!(one.unwrap().starts_with("outcome: done."));
    assert!(two.unwrap().starts_with("outcome: noop."));
    let cancel = |sp: &Arc<Spawner>| {
        let a = sp.clone();
        move || {
            a.control(ControlCall {
                action: "cancel".into(),
                id: Some("a1".into()),
                ..ControlCall::default()
            })
        }
    };
    let first = run(&mut h, cancel(&sp)).unwrap();
    assert!(first.starts_with("outcome: done."), "{first}");
    assert_eq!(h.agents.inner.lock().unwrap().cancels.len(), 1);
    // Its background shells end with the turn.
    assert_eq!(h.agents.inner.lock().unwrap().killed_processes.len(), 1);
    let second = run(&mut h, cancel(&sp)).unwrap();
    assert!(second.starts_with("outcome: noop."), "{second}");
    assert_eq!(h.agents.inner.lock().unwrap().cancels.len(), 1);
    let a = sp.clone();
    let status = run(&mut h, move || {
        a.control(ControlCall {
            action: "status".into(),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(status.contains("a1 [cancelled]"), "{status}");
    let a = sp.clone();
    let none = run(&mut h, move || a.tell("a9", "hi"));
    assert_eq!(none.unwrap_err(), "no subagent a9");
}
