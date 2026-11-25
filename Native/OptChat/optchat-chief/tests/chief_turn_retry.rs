//! The Chief carries a task to completion (issue 25577): a turn that a
//! passing model or network error cut runs again instead of posting the
//! failure, a network cut waits for the model endpoint instead of giving up
//! after a fixed backoff, a host that quits while it waits resumes the task,
//! and a turn is told its subagents' tasks are not done while they run.

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::auto_resume::{Reachability, ResumePolicy};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::{Value, json};

/// Turn 0 says a word and then fails (the harness error arrives as the
/// prompt's answer); later turns run as the default does.
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

fn prompts(h: &Harness) -> usize {
    h.agents.inner.lock().unwrap().prompts.len()
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
        .filter(|t| t.contains("turn failed"))
        .collect()
}

/// Steps inputs and fires due timers until the brain is idle with no timer
/// due before `within`.
fn settle_with_timers(h: &mut Harness, within: Duration) {
    let deadline = Instant::now() + within;
    loop {
        assert!(Instant::now() < deadline, "the brain did not settle");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        match h.brain.next_timer() {
            Some(at) if at < deadline => {
                std::thread::sleep(at.saturating_duration_since(Instant::now()));
                h.brain.on_timer();
            }
            _ if h.brain.is_idle() => return,
            _ => {}
        }
    }
}

/// Starts turn 0 on `text`, which fails with `error`.
fn failing_turn(error: &str, text: &str) -> Harness {
    let mut h = Harness::new(cut_first_script());
    h.brain
        .set_upstream_resume_backoff(vec![Duration::from_millis(200)]);
    h.agents.inner.lock().unwrap().answer_error = Some(error.into());
    h.connect();
    h.say("user_local", text);
    while prompts(&h) == 0 {
        h.step();
    }
    h
}

/// Offline for the first `offline` probes, then online; counts the probes.
struct Flaky {
    offline: u32,
    probes: AtomicU32,
}

impl Reachability for Flaky {
    fn online(&self) -> bool {
        self.probes.fetch_add(1, Ordering::SeqCst) >= self.offline
    }
}

#[test]
fn a_turn_cut_by_a_rate_limit_runs_again_after_a_backoff() {
    let mut h = failing_turn(
        "API Error: 429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Number of request tokens has exceeded your per-minute rate limit\"}}",
        "land the contrast fix",
    );
    let began = Instant::now();
    settle_with_timers(&mut h, WAIT);
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
    assert_eq!(prompts(&h), 2, "ran again once");
    assert!(began.elapsed() >= Duration::from_millis(200), "it waits");
    let resumed = prompt_text(&h, 1);
    assert!(resumed.contains("land the contrast fix"), "{resumed}");
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 1")),
        "{sends:?}"
    );
}

#[test]
fn a_turn_cut_by_an_overloaded_or_500_error_runs_again() {
    for error in [
        "API Error: 500 {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"Internal server error\"}}",
        "API Error: Overloaded",
    ] {
        let mut h = failing_turn(error, "check the build");
        settle_with_timers(&mut h, WAIT);
        assert!(failures(&h).is_empty(), "{error}: {:?}", failures(&h));
        assert_eq!(prompts(&h), 2, "{error}: ran again once");
    }
}

#[test]
fn a_turn_cut_by_a_network_error_waits_for_the_endpoint_then_runs_again() {
    let mut h = Harness::new(cut_first_script());
    let probe = Arc::new(Flaky {
        offline: 3,
        probes: AtomicU32::new(0),
    });
    h.brain
        .set_auto_resume(Some(ResumePolicy::default()), Some(probe.clone()));
    h.brain.set_network_poll(Duration::from_millis(100));
    h.brain
        .set_upstream_resume_backoff(vec![Duration::from_millis(10)]);
    h.agents.inner.lock().unwrap().answer_error = Some(
        "API Error: Connection error. (cause: fetch failed, ENOTFOUND api.anthropic.com)".into(),
    );
    h.connect();
    h.say("user_local", "rebase a187");
    while prompts(&h) == 0 {
        h.step();
    }
    // The cut waits while the endpoint does not answer; its timer is only
    // the bound of that wait, far away.
    let began = Instant::now();
    settle_with_timers(&mut h, WAIT);
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
    assert!(
        probe.probes.load(Ordering::SeqCst) >= 4,
        "it waited for the endpoint"
    );
    assert!(
        began.elapsed() >= Duration::from_millis(300),
        "not before the endpoint answered: {:?}",
        began.elapsed()
    );
    assert_eq!(prompts(&h), 2, "ran again once");
    let resumed = prompt_text(&h, 1);
    assert!(resumed.contains("rebase a187"), "{resumed}");
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 1")),
        "{sends:?}"
    );
}

/// The Mac stays offline and the person quits cmux (Cmd+Q) while the cut
/// turn waits: the next host runs the task again and answers it once.
#[test]
fn a_task_waiting_on_the_network_resumes_after_a_relaunch() {
    let mut h = Harness::new(cut_first_script());
    let never = Arc::new(Flaky {
        offline: u32::MAX,
        probes: AtomicU32::new(0),
    });
    h.brain
        .set_auto_resume(Some(ResumePolicy::default()), Some(never));
    h.brain.set_network_poll(Duration::from_millis(50));
    h.agents.inner.lock().unwrap().answer_error =
        Some("API Error: Connection error. (cause: socket hang up)".into());
    h.connect();
    h.say("user_local", "finish the migration");
    while prompts(&h) == 0 {
        h.step();
    }
    // The turn ends cut, then nothing runs while offline.
    let quiet = Instant::now() + Duration::from_millis(500);
    while Instant::now() < quiet {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    assert_eq!(prompts(&h), 1, "no retry while offline");
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
    assert_eq!(prompts(&h), 1, "the next host runs the task once");
    let resumed = prompt_text(&h, 0);
    assert!(resumed.contains("nothing was lost: go on"), "{resumed}");
    assert!(resumed.contains("finish the migration"), "{resumed}");
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "answered once: {sends:?}");
    assert!(failures(&h).is_empty(), "{:?}", failures(&h));
}

/// A usage limit does not clear on a retry: the turn fails at once, as
/// before, instead of looping.
#[test]
fn a_usage_limit_still_fails_the_turn() {
    let mut h = failing_turn(
        "API Error: You've hit your weekly limit · resets Oct 30, 9am",
        "check the build",
    );
    settle_with_timers(&mut h, WAIT);
    assert_eq!(prompts(&h), 1, "not retried");
    let failed = failures(&h);
    assert_eq!(failed.len(), 1, "{failed:?}");
    assert!(failed[0].contains("weekly limit"), "{failed:?}");
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

/// The subagent's turn ("build the thing") never ends; the Chief's turns
/// run as the default does.
fn endless_subagent() -> Script {
    let full = default_script();
    Box::new(move |turn, blocks| {
        if serde_json::to_string(blocks)
            .unwrap()
            .contains("build the thing")
        {
            return vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})];
        }
        full(turn, blocks)
    })
}

/// A turn that runs while a subagent works on the task is told the task is
/// not done, so it does not report it finished.
#[test]
fn a_turn_with_a_subagent_at_work_is_told_its_task_is_not_done() {
    let mut h = Harness::new(endless_subagent());
    h.connect();
    h.agents.inner.lock().unwrap().answer_never = true;
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let spawned = run(&mut h, move || {
        sp.spawn(vec!["build the thing".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    let before = prompts(&h);
    h.say("user_local", "is it done?");
    h.settle_posts();
    let turn = (before..prompts(&h))
        .map(|n| prompt_text(&h, n))
        .find(|p| p.contains("is it done?"))
        .expect("a turn ran on the message");
    assert!(turn.contains("Subagents at work now: a1."), "{turn}");
    assert!(turn.contains("not done until each reports"), "{turn}");
}
