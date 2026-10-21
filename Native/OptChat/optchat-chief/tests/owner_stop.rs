//! chief.stop: a turn the owner stopped posts nothing to the conversation
//! (and so to no bridge), however it ends. The owner pressed stop and
//! already knows (Lawrence 2026-10-19).

mod common;

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::Duration;

use cmux_conversation::Op;
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::state::{HostState, StateFile, SubStatus};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;

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
/// owner's stop ends each stopped subagent's background processes too.
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
    owner_stop(&mut h);
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
