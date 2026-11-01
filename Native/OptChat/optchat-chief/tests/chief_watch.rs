//! The Chief's `watch` tool (the user, 2026-10-29: "root cause for this is
//! likely bc chief doesnt have a monitor/loop tool, and we need to fix
//! that"). A promise like "I'll continue when you finish signing in" is a
//! real job: the host runs the command off the turn and wakes the Chief once
//! with a `[watch w<N>]` note when its output matches, it exits, or it times
//! out; a saved watch survives a host restart, and the host kills the watch's
//! process group when it stops.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Call, Orchestrator, WatchCall};
use serde_json::json;

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

/// Runs `f` on its own thread while the brain takes its inputs.
fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

fn watch(h: &mut Harness, call: WatchCall) -> Result<String, String> {
    let sp = spawner(h);
    run(h, move || sp.watch(call))
}

/// Every prompt the fake agent took, as JSON text.
fn prompts(h: &Harness) -> Vec<String> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .prompts
        .iter()
        .map(|p| serde_json::to_string(p).unwrap())
        .collect()
}

/// Steps the brain until a prompt contains `needle` (or `within` passes);
/// answers the prompts that contain it.
fn pump_until(h: &mut Harness, needle: &str, within: Duration) -> Vec<String> {
    let deadline = Instant::now() + within;
    loop {
        let found: Vec<String> = prompts(h)
            .into_iter()
            .filter(|p| p.contains(needle))
            .collect();
        if !found.is_empty() || Instant::now() >= deadline {
            return found;
        }
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
        if let Some(at) = h.brain.next_timer()
            && at <= Instant::now()
        {
            h.brain.on_timer();
        }
    }
}

fn idle(h: &mut Harness) {
    h.connect();
    h.say("user_local", "set up AWS for me");
    h.settle_posts();
}

#[test]
fn watch_wakes_the_chief_once_when_the_output_matches() {
    let mut h = Harness::new(default_script());
    idle(&mut h);
    let answer = watch(
        &mut h,
        WatchCall {
            command: Some(
                "echo waiting; sleep 0.3; echo 'Account: 1234 SIGNED_IN'; sleep 30".into(),
            ),
            until: Some("SIGNED_IN".into()),
            timeout_seconds: None,
            note: Some("finish the AWS setup".into()),
            cancel: None,
        },
    )
    .expect("watch answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    assert!(answer.contains("w1"), "{answer}");
    assert_eq!(h.brain.pending_watches().len(), 1);
    let fired = pump_until(&mut h, "[watch w1]", Duration::from_secs(10));
    assert_eq!(fired.len(), 1, "one wake: {:?}", prompts(&h));
    let text = &fired[0];
    assert!(text.contains("finish the AWS setup"), "{text}");
    assert!(text.contains("matched"), "{text}");
    assert!(
        text.contains("Account: 1234 SIGNED_IN"),
        "the last output: {text}"
    );
    h.settle_posts();
    assert!(h.brain.pending_watches().is_empty());
    // Exactly once: nothing more comes.
    let again = pump_until(&mut h, "never-in-a-prompt", Duration::from_secs(1));
    assert!(again.is_empty());
    let fired = prompts(&h)
        .into_iter()
        .filter(|p| p.contains("[watch w1]"))
        .count();
    assert_eq!(fired, 1, "the watch fired once");
}

#[test]
fn watch_wakes_the_chief_when_it_times_out() {
    let mut h = Harness::new(default_script());
    idle(&mut h);
    watch(
        &mut h,
        WatchCall {
            command: Some("echo still waiting; sleep 30".into()),
            until: Some("SIGNED_IN".into()),
            // Below the tool's floor: the parse holds the floor, the brain
            // takes what it is given.
            timeout_seconds: Some(1),
            note: Some("check the sign-in".into()),
            cancel: None,
        },
    )
    .expect("watch answers");
    let fired = pump_until(&mut h, "[watch w1]", Duration::from_secs(10));
    assert_eq!(fired.len(), 1, "{:?}", prompts(&h));
    assert!(fired[0].contains("check the sign-in"), "{}", fired[0]);
    assert!(fired[0].contains("timed out"), "{}", fired[0]);
    assert!(fired[0].contains("still waiting"), "{}", fired[0]);
    h.settle_posts();
    assert!(h.brain.pending_watches().is_empty());
}

#[test]
fn watch_survives_a_host_restart_and_the_old_host_kills_its_process() {
    let mut h = Harness::new(default_script());
    idle(&mut h);
    let flag = h.dir.path().join("signed-in");
    let pid_file = h.dir.path().join("watch.pid");
    let command = format!(
        "echo $$ > '{}'; while [ ! -f '{}' ]; do sleep 0.1; done; echo SIGNED_IN",
        pid_file.display(),
        flag.display()
    );
    watch(
        &mut h,
        WatchCall {
            command: Some(command),
            until: Some("SIGNED_IN".into()),
            timeout_seconds: None,
            note: Some("go on with the deploy".into()),
            cancel: None,
        },
    )
    .expect("watch answers");
    let deadline = Instant::now() + Duration::from_secs(10);
    let pid: i32 = loop {
        if let Some(pid) = std::fs::read_to_string(&pid_file)
            .ok()
            .and_then(|s| s.trim().parse().ok())
        {
            break pid;
        }
        assert!(Instant::now() < deadline, "the watch never started");
        std::thread::sleep(Duration::from_millis(20));
    };
    // The host stops.
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
    let deadline = Instant::now() + Duration::from_secs(5);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(
            Instant::now() < deadline,
            "the stopped host left the watch's process {pid} running"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // The next host takes the saved watch and runs it again.
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.settle_posts();
    assert_eq!(h.brain.pending_watches().len(), 1, "the watch was saved");
    h.brain.rearm_watches();
    std::fs::write(&flag, "yes").unwrap();
    let fired = pump_until(&mut h, "[watch w1]", Duration::from_secs(10));
    assert_eq!(fired.len(), 1, "{:?}", prompts(&h));
    assert!(fired[0].contains("go on with the deploy"), "{}", fired[0]);
    h.settle_posts();
    assert!(h.brain.pending_watches().is_empty());
}

#[test]
fn watch_lists_cancels_and_holds_its_bounds() {
    let parse = |v: serde_json::Value| Call::parse("watch", &v);
    assert!(
        parse(json!({"command": "true", "timeout_seconds": 5})).is_err(),
        "under 10 s"
    );
    assert!(
        parse(json!({"command": "true", "timeout_seconds": 100000})).is_err(),
        "over 24 h"
    );
    assert!(
        parse(json!({"command": "true", "until": "("})).is_err(),
        "a bad regex"
    );
    assert!(
        parse(json!({"until": "x"})).is_err(),
        "until needs a command"
    );
    assert!(parse(json!({})).is_ok(), "no arguments lists");
    assert!(parse(json!({"cancel": "w1"})).is_ok());
    let mut h = Harness::new(default_script());
    idle(&mut h);
    let pid_file = h.dir.path().join("watch.pid");
    watch(
        &mut h,
        WatchCall {
            command: Some(format!("echo $$ > '{}'; sleep 30", pid_file.display())),
            until: Some("never".into()),
            note: Some("a long one".into()),
            ..WatchCall::default()
        },
    )
    .unwrap();
    let listed = watch(&mut h, WatchCall::default()).unwrap();
    assert!(
        listed.contains("w1") && listed.contains("a long one"),
        "{listed}"
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    let pid: i32 = loop {
        if let Some(pid) = std::fs::read_to_string(&pid_file)
            .ok()
            .and_then(|s| s.trim().parse().ok())
        {
            break pid;
        }
        assert!(Instant::now() < deadline, "the watch never started");
        std::thread::sleep(Duration::from_millis(20));
    };
    let cancelled = watch(
        &mut h,
        WatchCall {
            cancel: Some("w1".into()),
            ..WatchCall::default()
        },
    )
    .unwrap();
    assert!(cancelled.starts_with("outcome: done"), "{cancelled}");
    assert!(h.brain.pending_watches().is_empty());
    let deadline = Instant::now() + Duration::from_secs(5);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(Instant::now() < deadline, "cancel left {pid} running");
        std::thread::sleep(Duration::from_millis(20));
    }
    // A cancelled watch never wakes the Chief.
    assert!(pump_until(&mut h, "[watch w1]", Duration::from_secs(1)).is_empty());
    for n in 0..optchat_chief::tools::WATCHES_KEPT {
        watch(
            &mut h,
            WatchCall {
                command: Some("sleep 30".into()),
                until: Some("never".into()),
                note: Some(format!("watch {n}")),
                ..WatchCall::default()
            },
        )
        .unwrap();
    }
    let over = watch(
        &mut h,
        WatchCall {
            command: Some("sleep 30".into()),
            ..WatchCall::default()
        },
    );
    assert!(over.is_err(), "the cap holds: {over:?}");
    let all = watch(
        &mut h,
        WatchCall {
            cancel: Some("all".into()),
            ..WatchCall::default()
        },
    )
    .unwrap();
    assert!(
        all.contains(&optchat_chief::tools::WATCHES_KEPT.to_string()),
        "{all}"
    );
    assert!(h.brain.pending_watches().is_empty());
}
