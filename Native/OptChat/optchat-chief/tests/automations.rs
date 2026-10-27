//! The Chief's automations (issue 25573): "Every morning at 9, summarize my
//! open PRs" makes an automation that runs at 9 and posts in the chat; event
//! triggers (a subagent done) fire once per event; nothing polls GitHub
//! (a CI event is the Cloud Chief's webhook job); the owner lists,
//! pauses, resumes and deletes them (Home's Chief settings).

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::automations::{Cron, Event};
use optchat_chief::brain::{AutomationsRequest, Input};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Call, Orchestrator};
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

/// The Chief's `automation` tool, through the host's orchestrator.
fn automation(h: &mut Harness, args: Value) -> Result<String, String> {
    let call = match Call::parse("automation", &args)? {
        Call::Automation(call) => call,
        other => panic!("{other:?}"),
    };
    let sp = spawner(h);
    run(h, move || sp.automation(call))
}

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

fn automation_notes(h: &Harness) -> Vec<String> {
    h.log()
        .into_iter()
        .map(|(_, t)| t)
        .filter(|t| t.contains("[automation au"))
        .collect()
}

#[test]
fn every_morning_at_nine_runs_at_nine_and_posts_in_the_chat() {
    let mut h = Harness::new(default_script());
    h.connect();
    let answer = automation(
        &mut h,
        json!({"action": "add", "name": "Morning PRs", "prompt": "Summarize my open PRs", "cron": "0 9 * * *"}),
    )
    .expect("add answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    let made = h.brain.automations()[0].clone();
    assert_eq!(made.id, "au1");
    let nine = made.next_ms.expect("a schedule has its next fire");
    assert_eq!(
        Some(nine),
        Cron::parse("0 9 * * *")
            .unwrap()
            .next_local_ms(made.created_ms)
    );
    let local = chrono::TimeZone::timestamp_millis_opt(&chrono::Local, nine as i64).unwrap();
    assert_eq!(chrono::Timelike::hour(&local), 9);
    assert_eq!(chrono::Timelike::minute(&local), 0);

    // Not due yet: nothing runs.
    let before = prompts(&h).len();
    h.brain.fire_automations_at(nine - 1);
    h.settle_posts();
    assert_eq!(prompts(&h).len(), before);

    // At 9: one turn with the automation's prompt, and its reply is posted.
    let sent_before = h.owner.lock().unwrap().sends().len();
    h.brain.fire_automations_at(nine);
    h.settle_posts();
    let all = prompts(&h);
    assert_eq!(all.len(), before + 1, "one turn ran");
    let last = all.last().unwrap();
    assert!(
        last.contains("[automation au1") && last.contains("Summarize my open PRs"),
        "{last}"
    );
    assert!(
        h.owner.lock().unwrap().sends().len() > sent_before,
        "the turn's reply posted in the Chief conversation"
    );

    // It goes on to tomorrow's 9, and the same minute never fires twice.
    let fired = h.brain.automations()[0].clone();
    assert_eq!(fired.runs, 1);
    assert_eq!(fired.last_fired_ms, Some(nine));
    let next = fired.next_ms.unwrap();
    // 23 h on the day the clocks go forward.
    assert!(next >= nine + 23 * 3600 * 1000, "{next} after {nine}");
    h.brain.fire_automations_at(nine);
    h.settle_posts();
    assert_eq!(prompts(&h).len(), before + 1);
}

#[test]
fn a_schedule_missed_while_the_host_was_down_fires_once_late() {
    let mut h = Harness::new(default_script());
    h.connect();
    automation(
        &mut h,
        json!({"action": "add", "prompt": "Post the nightly status", "cron": "0 * * * *"}),
    )
    .unwrap();
    let first = h.brain.automations()[0].next_ms.unwrap();
    // Three days later: one fire, not 72.
    let later = first + 3 * 86_400_000;
    h.brain.fire_automations_at(later);
    h.settle_posts();
    let notes = automation_notes(&h);
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].contains("late"), "{}", notes[0]);
    let a = &h.brain.automations()[0];
    assert_eq!(a.runs, 1);
    assert!(a.next_ms.unwrap() > later);
}

#[test]
fn the_owner_lists_pauses_resumes_and_deletes_them() {
    let mut h = Harness::new(default_script());
    h.connect();
    automation(
        &mut h,
        json!({"action": "add", "name": "Digest", "prompt": "digest", "cron": "@daily"}),
    )
    .unwrap();
    automation(
        &mut h,
        json!({"action": "add", "name": "Review", "prompt": "review the finished work", "event": "agent_done", "match": "fix"}),
    )
    .unwrap();
    let list = h.brain.automations_control(AutomationsRequest::List);
    let items = list["automations"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["name"], "Digest");
    assert_eq!(items[0]["trigger"]["type"], "schedule");
    assert_eq!(items[0]["trigger"]["cron"], "@daily");
    assert!(items[0]["next_ms"].is_u64());
    assert_eq!(items[1]["trigger"]["type"], "agent_done");
    assert_eq!(items[1]["trigger"]["matches"], "fix");
    assert!(items[1]["next_ms"].is_null(), "an event has no next time");

    // Paused: no next fire, and a due time passes with no turn.
    let due = h.brain.automations()[0].next_ms.unwrap();
    let paused = h.brain.automations_control(AutomationsRequest::Update {
        id: "au1".into(),
        action: "pause".into(),
    });
    assert_eq!(paused["outcome"], "done");
    assert_eq!(paused["automations"][0]["paused"], true);
    assert!(paused["automations"][0]["next_ms"].is_null());
    h.brain.fire_automations_at(due);
    h.settle_posts();
    assert!(automation_notes(&h).is_empty());
    // A repeat is a noop.
    let again = h.brain.automations_control(AutomationsRequest::Update {
        id: "au1".into(),
        action: "pause".into(),
    });
    assert_eq!(again["outcome"], "noop");

    let resumed = h.brain.automations_control(AutomationsRequest::Update {
        id: "au1".into(),
        action: "resume".into(),
    });
    assert_eq!(resumed["automations"][0]["paused"], false);
    assert!(resumed["automations"][0]["next_ms"].is_u64());

    let deleted = h.brain.automations_control(AutomationsRequest::Update {
        id: "au2".into(),
        action: "delete".into(),
    });
    assert_eq!(deleted["automations"].as_array().unwrap().len(), 1);
    let missing = h.brain.automations_control(AutomationsRequest::Update {
        id: "au2".into(),
        action: "delete".into(),
    });
    assert_eq!(missing["error"]["code"], "not_found");
    let bad = h.brain.automations_control(AutomationsRequest::Update {
        id: "au1".into(),
        action: "explode".into(),
    });
    assert_eq!(bad["error"]["code"], "bad_request");

    // They outlive the host: a new brain over the same home has them.
    let dir = std::mem::replace(&mut h.dir, tempfile::tempdir().unwrap());
    let owner = h.owner.clone();
    drop(h);
    let h2 = Harness::in_dir(dir, default_script(), owner);
    let kept = h2.brain.automations();
    assert_eq!(kept.len(), 1);
    assert_eq!(kept[0].name, "Digest");
    assert!(!kept[0].paused);
}

#[test]
fn the_same_job_asked_twice_is_one_automation_and_the_cap_holds() {
    let mut h = Harness::new(default_script());
    h.connect();
    let add = json!({"action": "add", "prompt": "same", "cron": "0 9 * * *"});
    automation(&mut h, add.clone()).unwrap();
    let again = automation(&mut h, add).unwrap();
    assert!(again.starts_with("outcome: noop"), "{again}");
    for n in 1..optchat_chief::automations::AUTOMATIONS_MAX {
        automation(
            &mut h,
            json!({"action": "add", "prompt": format!("job {n}"), "cron": "0 9 * * *"}),
        )
        .unwrap();
    }
    let full = automation(
        &mut h,
        json!({"action": "add", "prompt": "one too many", "cron": "0 9 * * *"}),
    );
    assert!(full.unwrap_err().contains("delete one first"));
}

/// A subagent's turn ends with a report; the Chief's turns with the default answer.
fn report_script() -> Script {
    let default = default_script();
    Box::new(move |turn, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        if !text.contains("CI-TASK") {
            return default(turn, blocks);
        }
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "Fixed the flaky test and pushed."}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

fn sub_session(h: &Harness) -> Option<String> {
    let inner = h.agents.inner.lock().unwrap();
    let k = inner
        .specs
        .iter()
        .position(|s| s.tags.contains_key("optchat.subagent"))?;
    let session = format!("s{}", k + 1);
    inner.prompt_sessions.contains(&session).then_some(session)
}

/// Spawns one subagent with `task` and steps the brain until its report is
/// in the log.
fn spawn_until_report(h: &mut Harness, task: &str, sub: &str) {
    let sp = spawner(h);
    let task = task.to_owned();
    let worker = std::thread::spawn(move || sp.spawn(vec![task], None));
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    let prefix = format!("[{sub}] ");
    while !h.log().iter().any(|(_, t)| t.starts_with(&prefix)) {
        assert!(Instant::now() < deadline, "no report: {:?}", h.log());
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        if !idle_sent
            && worker.is_finished()
            && let Some(session) = last_sub_session(h)
        {
            idle_sent = true;
            let idle: cmux_chief::acp::SessionSummary = serde_json::from_value(json!({
                "sessionId": session, "name": sub, "status": "idle", "harness": "claude",
            }))
            .unwrap();
            h.brain.step(Input::from(AgentEvent::SessionChanged(idle)));
        }
    }
    worker.join().unwrap().expect("the spawn answers");
    h.settle_posts();
}

/// The newest subagent's session once its first prompt is in.
fn last_sub_session(h: &Harness) -> Option<String> {
    let inner = h.agents.inner.lock().unwrap();
    let k = inner
        .specs
        .iter()
        .rposition(|s| s.tags.contains_key("optchat.subagent"))?;
    let session = format!("s{}", k + 1);
    inner.prompt_sessions.contains(&session).then_some(session)
}

#[test]
fn a_subagent_an_automations_turn_started_never_fires_agent_done() {
    let mut h = Harness::new(report_script());
    h.connect();
    automation(
        &mut h,
        json!({"action": "add", "name": "Review", "prompt": "Review what the agent did", "event": "agent_done"}),
    )
    .unwrap();
    // The automation's own turn (run now), and a subagent spawned after it.
    automation(&mut h, json!({"action": "run", "id": "au1"})).unwrap();
    h.settle_posts();
    assert_eq!(automation_notes(&h).len(), 1, "the run's own note");
    spawn_until_report(&mut h, "Title: Review\nCI-TASK review it", "a1");
    assert_eq!(
        automation_notes(&h).len(),
        1,
        "its own subagent did not fire it again: {:?}",
        automation_notes(&h)
    );
    // The person's next turn: its subagent fires it.
    h.say("user_local", "fix the flaky test");
    h.settle_posts();
    spawn_until_report(&mut h, "Title: Flaky\nCI-TASK fix it", "a2");
    assert_eq!(automation_notes(&h).len(), 2, "{:?}", automation_notes(&h));
}

#[test]
fn agent_done_fires_once_when_a_subagent_finishes() {
    let mut h = Harness::new(report_script());
    h.connect();
    automation(
        &mut h,
        json!({"action": "add", "name": "Review", "prompt": "Review what the agent did", "event": "agent_done"}),
    )
    .unwrap();
    let sp = spawner(&h);
    let worker =
        std::thread::spawn(move || sp.spawn(vec!["Title: CI fix\nCI-TASK fix it".into()], None));
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    while automation_notes(&h).is_empty() {
        assert!(
            Instant::now() < deadline,
            "no automation fired: {:?}",
            h.log()
        );
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        if !idle_sent
            && worker.is_finished()
            && let Some(session) = sub_session(&h)
        {
            idle_sent = true;
            let idle: cmux_chief::acp::SessionSummary = serde_json::from_value(json!({
                "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
            }))
            .unwrap();
            h.brain.step(Input::from(AgentEvent::SessionChanged(idle)));
        }
    }
    worker.join().unwrap().expect("the spawn answers");
    h.settle_posts();
    let notes = automation_notes(&h);
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(
        notes[0].contains("Review what the agent did"),
        "{}",
        notes[0]
    );
    assert!(notes[0].contains("subagent a1"), "{}", notes[0]);
    assert!(notes[0].contains("Fixed the flaky test"), "{}", notes[0]);
    // The same run's end again (a replayed report): no second fire.
    let a = h.brain.automations()[0].clone();
    let key = a.fired.last().cloned().expect("the event's key is kept");
    let run_ms = key.rsplit(':').next().unwrap().parse().unwrap();
    h.brain.automation_event(Event::AgentDone {
        id: "a1".into(),
        title: "CI fix".into(),
        run_ms,
        report: "again".into(),
    });
    h.settle_posts();
    assert_eq!(automation_notes(&h).len(), 1);
    assert_eq!(h.brain.automations()[0].runs, 1);
}

/// Failed runs a test hands out.

#[test]
fn a_github_event_is_not_a_local_automation() {
    let mut h = Harness::new(default_script());
    h.connect();
    let refused = automation(
        &mut h,
        json!({"action": "add", "prompt": "fix", "event": "ci_red", "repo": "o/r"}),
    );
    assert!(refused.is_err(), "{refused:?}");
    assert!(h.brain.automations().is_empty());
}
