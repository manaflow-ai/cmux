//! After work, the Chief shows it beside its chat (Lawrence 2026-10-20: "as a
//! default behavior for the Chief, when submissions are done, think about what
//! else would be useful to show in the workspace ... a column to the right to
//! show a browser preview or a diff"). A subagent's report that names landed
//! commits, pages or preview files reaches the Chief with a `<show>` block
//! that opens each in the right column; `show.afterReport` turns it off.

mod common;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::daemon::OpError;
use optchat_chief::show;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::{Value, json};

const REPORT: &str = "Landed 1a2b3c4d5e6..9f8e7d6c5b4 on feat-cmux-next ([9f8e7d6](https://github.com/manaflow-ai/cmux/commit/9f8e7d6c5b4a)). Gallery: [index.html](file:///Users/me/fun/My%20Gallery/index.html), board at http://127.0.0.1:55999/.";

#[test]
fn a_landed_range_becomes_a_compare_page_in_the_right_column() {
    let block = show::block(REPORT).expect("the report names things to show");
    assert!(
        block.starts_with("<show>") && block.ends_with("</show>"),
        "{block}"
    );
    assert!(
        block.contains("cmux browser right navigate https://github.com/manaflow-ai/cmux/compare/1a2b3c4d5e6...9f8e7d6c5b4"),
        "{block}"
    );
    assert!(
        block.contains("cmux browser right navigate http://127.0.0.1:55999/"),
        "{block}"
    );
    // `right navigate` takes the URL as a word: `--url` is a usage error there (the
    // default Chief copied this hint 18 times from Oct 20 to 26; 17 got "cmux: usage").
    assert!(!block.contains("navigate --url"), "{block}");
    assert!(
        block.contains("--path '/Users/me/fun/My Gallery/index.html' --where tab"),
        "{block}"
    );
    // The commit link is covered by the diff line, not a page of its own.
    assert!(!block.contains("- page https://github.com"), "{block}");
    assert!(block.contains("never the dock"), "{block}");
}

#[test]
fn a_report_with_nothing_to_show_gets_no_block() {
    assert_eq!(
        show::block(
            "Not stuck: waiting on two Mac-mini runs (1234567 queued), see cmux://workspace/ws_1."
        ),
        None
    );
    assert_eq!(show::block("Nothing landed: tests are red."), None);
}

#[test]
fn a_range_without_a_github_link_reads_the_log_in_a_terminal() {
    let block = show::block("Pushed abcdef0..1234abc.").expect("a range");
    assert!(block.contains("git log -p abcdef0..1234abc"), "{block}");
}

#[test]
fn show_after_report_is_on_by_default_and_is_a_setting() {
    let mut h = Harness::new(default_script());
    let file = h.dir.path().join("settings.json");
    assert!(optchat_chief::chief_settings::ChiefSettings::load(&file).show_after_report);
    let answer = h
        .brain
        .set_setting("show.afterReport", "false")
        .expect("show.afterReport is a setting");
    assert_eq!(answer, "show.afterReport = false");
    assert!(h.brain.set_setting("show.afterReport", "maybe").is_err());
}

/// A subagent's turn ends with `REPORT`; the Chief's turns with the default answer.
fn report_script() -> Script {
    let default = default_script();
    Box::new(move |turn, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        if !text.contains("SHOW-TASK") {
            return default(turn, blocks);
        }
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": REPORT}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

/// Spawns one subagent and steps the brain until its report is in the log.
fn delivered_report(h: &mut Harness) -> String {
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
    h.connect();
    let worker = std::thread::spawn(move || spawner.spawn(vec!["SHOW-TASK land it".into()], None));
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    loop {
        if let Some((_, text)) = h.log().into_iter().find(|(_, t)| t.starts_with("[a1] ")) {
            worker.join().unwrap().expect("the spawn answers");
            return text;
        }
        assert!(Instant::now() < deadline, "no report: {:?}", h.log());
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        // The subagent's turn ran (its report is in its events): its
        // session goes idle, as acpmux reports it.
        if !idle_sent
            && worker.is_finished()
            && let Some(session) = sub_session(h)
        {
            idle_sent = true;
            h.brain
                .step(Input::from(AgentEvent::SessionChanged(idle(&session))));
        }
    }
}

/// The subagent's session once its first prompt is in.
fn sub_session(h: &Harness) -> Option<String> {
    let inner = h.agents.inner.lock().unwrap();
    let k = inner
        .specs
        .iter()
        .position(|s| s.tags.contains_key("optchat.subagent"))?;
    let session = format!("s{}", k + 1);
    inner.prompt_sessions.contains(&session).then_some(session)
}

fn idle(session: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
    }))
    .unwrap()
}

#[test]
fn a_finished_subagents_report_reaches_the_chief_with_what_to_show() {
    let mut h = Harness::new(report_script());
    let text = delivered_report(&mut h);
    assert!(text.contains("<show>"), "{text}");
    assert!(text.contains("compare/1a2b3c4d5e6...9f8e7d6c5b4"), "{text}");
}

#[test]
fn show_after_report_off_delivers_the_bare_report() {
    let mut h = Harness::new(report_script());
    h.brain
        .set_setting("show.afterReport", "false")
        .expect("a setting");
    let text = delivered_report(&mut h);
    assert!(text.contains("Landed 1a2b3c4d5e6"), "{text}");
    assert!(!text.contains("<show>"), "{text}");
}

#[test]
fn an_inbound_report_has_a_completed_record_after_its_originating_turn_ends() {
    let mut h = Harness::new(report_script());
    h.connect();
    h.say("user_local", "Please coordinate the work.");
    h.settle();
    let origin = h.owner.lock().unwrap().runs.last().unwrap().clone();
    delivered_report(&mut h);
    let owner = h.owner.lock().unwrap();
    let notes: Vec<_> = owner
        .run_steps
        .iter()
        .flat_map(|(conversation, run, steps)| {
            steps
                .iter()
                .filter(|step| step["kind"] == "note")
                .map(move |step| (conversation, run, step))
        })
        .collect();
    assert!(
        !notes.is_empty(),
        "the report must be visible without a Chief paraphrase"
    );
    for (conversation, run, step) in notes {
        assert_eq!(conversation, CONV);
        assert_eq!(
            run["id"],
            optchat_chief::run::report_run_id(origin["id"].as_str().unwrap())
        );
        assert_ne!(run["id"], origin["id"]);
        assert_eq!(run["answers"], origin["answers"]);
        assert_eq!(step["text"], format!("[a1] {REPORT}"));
        assert_eq!(
            run["status"], "done",
            "a missing report record must not start a run"
        );
        assert!(
            run.get("turn").is_none(),
            "reports must not replace the reply's tool run"
        );
    }
}

#[test]
fn a_report_append_retries_after_an_ambiguous_failure_without_duplicate_steps() {
    let mut h = Harness::new(report_script());
    h.connect();
    h.say("user_local", "Please coordinate the work.");
    h.settle();
    h.owner
        .lock()
        .unwrap()
        .run_append_rejects
        .push_back(Some(OpError::Transport(
            "connection reset after commit".into(),
        )));
    let _ = delivered_report(&mut h);
    assert!(!h.brain.state().pending_reports.is_empty());
    assert_eq!(h.owner.lock().unwrap().reconnects, 1);

    // A daemon reconnect flushes the durable outbox. The fake records both
    // the ambiguous first attempt and its replay; the owner would upsert the
    // stable run/step ids rather than create a second visible row.
    h.connect();
    assert!(h.brain.state().pending_reports.is_empty());
    let owner = h.owner.lock().unwrap();
    let mut ids = Vec::new();
    let reports: Vec<_> = owner
        .run_steps
        .iter()
        .filter(|(_, run, _)| {
            run["id"]
                .as_str()
                .is_some_and(|id| id.starts_with("reports:"))
        })
        .collect();
    for (_, _, steps) in &reports {
        ids.extend(
            steps
                .iter()
                .filter_map(|step| step["id"].as_str().map(str::to_owned)),
        );
    }
    assert!(!ids.is_empty());
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 1, "the report has one stable note id");
    assert_eq!(reports.len(), 2, "one failed attempt and one replay");
}

#[test]
fn a_replayed_report_transport_failure_requests_reconnect() {
    let mut h = Harness::new(report_script());
    h.connect();
    h.say("user_local", "Please coordinate the work.");
    h.settle();
    h.owner
        .lock()
        .unwrap()
        .run_append_rejects
        .push_back(Some(OpError::Transport("first connection reset".into())));
    delivered_report(&mut h);
    assert!(!h.brain.state().pending_reports.is_empty());
    assert_eq!(h.owner.lock().unwrap().reconnects, 1);

    // The reconnect itself can lose its write too. The pending report must
    // stay durable, and this second failure must request another reconnect
    // rather than attempting later reports on the broken port.
    h.owner
        .lock()
        .unwrap()
        .run_append_rejects
        .push_back(Some(OpError::Transport("replay connection reset".into())));
    h.connect();
    assert!(!h.brain.state().pending_reports.is_empty());
    assert_eq!(h.owner.lock().unwrap().reconnects, 2);

    // A subsequent healthy connection flushes the retained report.
    h.connect();
    assert!(h.brain.state().pending_reports.is_empty());
}

#[test]
fn a_followup_report_stays_with_the_new_assignment_in_another_conversation() {
    let mut h = Harness::new(report_script());
    h.connect();
    h.say("user_local", "Please coordinate the original work.");
    h.settle();
    delivered_report(&mut h);
    h.settle();
    let old_notes = h.owner.lock().unwrap().run_steps.len();
    let session = sub_session(&h).expect("the existing agent");
    let prompts = h.agents.inner.lock().unwrap().prompts.len();
    h.agents.hold(true);
    h.add_side("conv_followup", "user_followup");
    let question = h.post_side("conv_followup", "user_followup", "Now check the follow-up.");
    h.wake(&[("conv_followup", question.seq)]);
    let deadline = Instant::now() + Duration::from_secs(20);
    while h.agents.inner.lock().unwrap().prompts.len() == prompts {
        assert!(
            Instant::now() < deadline,
            "the follow-up Chief turn did not start"
        );
        h.step();
    }
    let saved = optchat_chief::state::StateFile::new(&h.dir.path().join("host.json"))
        .attach(h.chat.clone())
        .load();
    let turn = saved.turn.expect("the held Chief turn").key;
    let (tx, rx) = std::sync::mpsc::channel();
    h.brain.step(Input::Tell {
        id: "a1".into(),
        message: "SHOW-TASK follow-up report".into(),
        key: None,
        queue: false,
        reply: tx,
    });
    assert!(
        rx.recv_timeout(Duration::from_secs(2))
            .unwrap()
            .unwrap()
            .starts_with("outcome: done")
    );
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    h.brain
        .step(Input::from(AgentEvent::SessionChanged(idle(&session))));
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let found = h
            .owner
            .lock()
            .unwrap()
            .run_steps
            .iter()
            .skip(old_notes)
            .any(|(conversation, run, steps)| {
                conversation == "conv_followup"
                    && run["id"] == optchat_chief::run::report_run_id(&turn)
                    && run["status"] == "done"
                    && run["answers"]
                        .as_array()
                        .is_some_and(|answers| answers.contains(&json!(question.id)))
                    && steps.iter().any(|step| {
                        step["kind"] == "note" && step["text"] == format!("[a1] {REPORT}")
                    })
            });
        if found {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the report did not follow its new assignment"
        );
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
}

#[test]
fn unsupported_report_storage_does_not_keep_a_permanent_outbox() {
    let mut h = Harness::new(report_script());
    h.connect();
    h.say("user_local", "Please coordinate the work.");
    h.settle();
    h.owner.lock().unwrap().runs_unsupported = true;
    assert!(delivered_report(&mut h).contains(REPORT));
    assert!(h.brain.state().pending_reports.is_empty());
}

#[test]
fn reconnect_to_a_port_without_runs_discards_unsupported_pending_reports() {
    let mut h = Harness::new(report_script());
    h.connect();
    h.say("user_local", "Please coordinate the work.");
    h.settle();
    h.owner
        .lock()
        .unwrap()
        .run_append_rejects
        .push_back(Some(OpError::Transport(
            "connection reset after commit".into(),
        )));
    delivered_report(&mut h);
    assert!(!h.brain.state().pending_reports.is_empty());
    h.owner.lock().unwrap().runs_unsupported = true;
    h.connect();
    assert!(h.brain.state().pending_reports.is_empty());
}

#[test]
fn a_legacy_spawn_without_a_route_delivers_but_does_not_project_into_home() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join("host.json"),
        serde_json::to_vec(&json!({
            "conversation": CONV,
            "spawns": {
                "s1": {
                    "subs": [{"id": "a1", "status": "running"}]
                }
            }
        }))
        .unwrap(),
    )
    .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, report_script(), owner);
    h.connect();
    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "legacy report".into(),
    });
    h.settle();

    let owner = h.owner.lock().unwrap();
    assert!(
        owner.run_steps.iter().all(|(_, run, _)| !run["id"]
            .as_str()
            .is_some_and(|id| id.starts_with("reports:"))),
        "a legacy report must not be projected without its saved route: {:?}",
        owner.run_steps
    );
    assert!(
        h.log()
            .iter()
            .any(|(_, text)| text.contains("[a1] (did not start: legacy report)")),
        "the report still reaches the Chief's normal conversation"
    );
}

#[test]
fn a_report_consumed_then_resumed_without_an_assignment_does_not_reuse_its_old_route() {
    let mut h = Harness::new(report_script());
    h.connect();
    h.say("user_local", "Please coordinate the work.");
    h.settle();
    delivered_report(&mut h);
    h.settle();
    let report_steps = |h: &Harness| {
        h.owner
            .lock()
            .unwrap()
            .run_steps
            .iter()
            .filter(|(_, run, _)| {
                run["id"]
                    .as_str()
                    .is_some_and(|id| id.starts_with("reports:"))
            })
            .count()
    };
    assert_eq!(
        h.brain.state().spawns["s1"].subs[0].status,
        optchat_chief::state::SubStatus::Reported
    );
    assert!(h.brain.state().spawns["s1"].subs[0].report_run.is_none());
    let before = report_steps(&h);

    // Model a resumed/standalone run that has no new assignment question.
    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "resumed without assignment".into(),
    });
    h.settle();
    assert_eq!(report_steps(&h), before);
    assert!(
        h.log()
            .iter()
            .any(|(_, text)| text.contains("[a1] (did not start: resumed without assignment)")),
        "the resumed report still reaches Chief"
    );
}
