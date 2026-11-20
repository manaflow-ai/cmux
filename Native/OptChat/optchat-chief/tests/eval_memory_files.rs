//! Chief fast eval, group memory (chief-memory lane, MEMORY-ALWAYS-ON.md):
//! the memory files over the host's tool socket, as the Chief's MCP server
//! and its `chief memory_*` launcher call them. A saved note and loop show in
//! the block every turn reads; a turn another person started may write
//! loops only; a subagent may not write at all; a forgotten note is never
//! written again by the nightly review; a check-in wakes only on open loops.
#![cfg(unix)]

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::memory_files::{MemoryFiles, Trust};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Call, Served, ask_as, serve_all};
use serde_json::json;

fn spawner(h: &Harness, files: Arc<MemoryFiles>) -> Arc<Spawner> {
    Arc::new(
        Spawner::new(
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
        )
        .with_memory_files(files),
    )
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

#[test]
fn notes_and_loops_saved_over_the_socket_reach_every_turn() {
    let mut h = Harness::new(default_script());
    let files = Arc::new(MemoryFiles::open_in(&h.dir.path().join("optchat")).unwrap());
    let socket = h.dir.path().join("tools.sock");
    serve_all(
        &socket,
        Served {
            memory: open_chat(&h.dir.path().join("memory")),
            orchestrator: Some(spawner(&h, files.clone())),
            control: None,
            inspector: None,
            chief: None,
            turn: None,
            peers: None,
            fork: None,
            mcp: None,
        },
    )
    .unwrap();
    let ask = |h: &mut Harness, tool: &str, args: serde_json::Value, subagent: bool| {
        let (s, c) = (socket.clone(), Call::parse(tool, &args).unwrap());
        run(h, move || ask_as(&s, c, subagent))
    };
    let rules = ask(
        &mut h,
        "memory_write",
        json!({"path": "notes/standing-rules.md", "description": "rules in the person's words",
               "body": "- \"whenever I ask you to update Linear, add the image\" (msg 12, 2026-11-19)"}),
        false,
    )
    .unwrap();
    assert!(rules.starts_with("outcome: done. saved"), "{rules}");
    let lp = ask(
        &mut h,
        "memory_write",
        json!({"path": "loops/renew-domain.md", "description": "renew cmux.dev before Fri 2026-11-20",
               "body": "Asked (2026-11-16, msg 3): renew cmux.dev\nLeft: all\nDue: 2026-11-20"}),
        false,
    )
    .unwrap();
    assert!(lp.starts_with("outcome: done"), "{lp}");
    // The block every turn reads: the loop in the index, the rules whole.
    let block = files.block().unwrap();
    assert!(
        block.contains("- loops/renew-domain.md: renew cmux.dev before Fri 2026-11-20"),
        "{block}"
    );
    assert!(
        block.contains("whenever I ask you to update Linear, add the image"),
        "{block}"
    );
    // memory_read answers the file and the index.
    let read = ask(
        &mut h,
        "memory_read",
        json!({"path": "loops/renew-domain.md"}),
        false,
    )
    .unwrap();
    assert!(read.contains("Due: 2026-11-20"), "{read}");
    let index = ask(&mut h, "memory_read", json!({"path": "index.md"}), false).unwrap();
    assert!(index.contains("notes/standing-rules.md"), "{index}");
    // Paths outside notes/ and loops/, and secrets, are refused.
    assert!(
        ask(
            &mut h,
            "memory_write",
            json!({"path": "../x.md", "description": "", "body": "x"}),
            false
        )
        .is_err()
    );
    assert!(ask(&mut h, "memory_write",
        json!({"path": "notes/keys.md", "description": "", "body": "token ghp_abcdefghijklmnopqrstuvwxyz0123"}), false).is_err());
    // A subagent cannot touch the Chief's memory files.
    let refused = ask(
        &mut h,
        "memory_write",
        json!({"path": "notes/x.md", "description": "x", "body": "x"}),
        true,
    );
    assert!(refused.is_err(), "{refused:?}");
    // A loop is forgotten when it ends; the history keeps it.
    let gone = ask(
        &mut h,
        "memory_forget",
        json!({"path": "loops/renew-domain.md"}),
        false,
    )
    .unwrap();
    assert!(gone.starts_with("outcome: done"), "{gone}");
    assert!(!files.block().unwrap().contains("renew-domain"));
}

#[test]
fn another_persons_turn_writes_loops_only_and_the_review_never_rewrites_a_forgotten_note() {
    let dir = tempfile::tempdir().unwrap();
    let files = MemoryFiles::open_in(dir.path()).unwrap();
    assert!(
        files
            .write(
                "notes/people.md",
                "who",
                "- Leo: M4 mini",
                Trust::Outside,
                "t"
            )
            .is_err()
    );
    assert!(
        files
            .write(
                "loops/ask-leo.md",
                "ask Leo",
                "Left: ask",
                Trust::Outside,
                "t"
            )
            .is_ok()
    );
    files
        .write(
            "notes/people.md",
            "who",
            "- Leo: M4 mini",
            Trust::Person,
            "t",
        )
        .unwrap();
    files.forget("notes/people.md", "person").unwrap();
    let ops = vec![
        json!({"op": "write", "path": "notes/people.md", "description": "who", "body": "- Leo: M4 mini"}),
    ];
    let applied = optchat_chief::dream::apply(
        &files,
        &ops,
        "dream:2026-11-19",
        true,
        &Default::default(),
        &Default::default(),
    );
    assert!(applied.written.is_empty(), "{applied:?}");
    assert!(files.get("notes/people.md").unwrap().is_none());
    // A note is a topic, never a day's log.
    let ops = vec![
        json!({"op": "write", "path": "notes/requests-2026-10-20.md", "description": "x", "body": "- x"}),
    ];
    let applied = optchat_chief::dream::apply(
        &files,
        &ops,
        "dream:2026-11-19",
        true,
        &Default::default(),
        &Default::default(),
    );
    assert!(applied.written.is_empty(), "{applied:?}");
    // A CVE id in a name is a topic, not a date.
    let ops = vec![
        json!({"op": "write", "path": "notes/cve-2026-118306.md", "description": "x", "body": "- x"}),
    ];
    let applied = optchat_chief::dream::apply(
        &files,
        &ops,
        "dream:2026-11-19",
        true,
        &Default::default(),
        &Default::default(),
    );
    assert_eq!(applied.written, ["notes/cve-2026-118306.md"], "{applied:?}");
    // A review over old messages makes no new loop.
    let ops = vec![
        json!({"op": "write", "path": "loops/old-ask.md", "description": "x", "body": "Left: x"}),
    ];
    let applied = optchat_chief::dream::apply(
        &files,
        &ops,
        "dream:2026-11-19",
        false,
        &Default::default(),
        &Default::default(),
    );
    assert!(applied.written.is_empty(), "{applied:?}");
}

#[test]
fn check_ins_come_on_the_cloud_schedule_and_only_with_open_loops() {
    use optchat_chief::check_in::{Mode, current_slot, next_slot, note};
    let at = |s: &str| chrono::DateTime::parse_from_rfc3339(s).unwrap();
    // Thursday 14:00: the 13:30 slot is current, 16:30 next.
    assert_eq!(
        current_slot(Mode::Auto, at("2026-11-19T14:00:00-08:00")).as_deref(),
        Some("2026-11-19 13:30")
    );
    assert_eq!(
        next_slot(Mode::Auto, at("2026-11-19T14:00:00-08:00")).unwrap(),
        at("2026-11-19T16:30:00-08:00")
    );
    // Friday after the last slot: Monday 09:30; no weekend slot in auto.
    assert_eq!(
        next_slot(Mode::Auto, at("2026-11-20T16:45:00-08:00")).unwrap(),
        at("2026-11-23T09:30:00-08:00")
    );
    assert_eq!(
        current_slot(Mode::Auto, at("2026-11-21T10:00:00-08:00")),
        None
    );
    assert_eq!(
        current_slot(Mode::Mornings, at("2026-11-21T10:00:00-08:00")).as_deref(),
        Some("2026-11-21 09:00")
    );
    assert_eq!(next_slot(Mode::Off, at("2026-11-19T14:00:00-08:00")), None);
    let text = note(
        &["- loops/renew-domain.md: renew cmux.dev (2026-11-19)".to_owned()],
        "2026-11-19 09:30",
    );
    assert!(
        text.starts_with("[check-in]")
            && text.contains("loops/renew-domain.md")
            && text.contains("nothing(reason)"),
        "{text}"
    );
}

#[test]
fn another_persons_loops_stay_theirs_and_the_review_takes_rules_only_from_the_person() {
    let dir = tempfile::tempdir().unwrap();
    let files = MemoryFiles::open_in(dir.path()).unwrap();
    // The owner's loop: another person's turn can neither read a note nor
    // remove the owner's loop; its own loop is marked as data in the index.
    files
        .write(
            "loops/renew.md",
            "renew cmux.dev",
            "Left: all",
            Trust::Person,
            "t",
        )
        .unwrap();
    files
        .write(
            "notes/people.md",
            "who",
            "- Leo: M4 mini",
            Trust::Person,
            "t",
        )
        .unwrap();
    assert!(
        files
            .forget_as("loops/renew.md", "x", Trust::Outside)
            .is_err()
    );
    let read = optchat_chief::tools::MemoryFileCall::Read {
        path: "notes/people.md".into(),
    }
    .answer(&files, "x", Trust::Outside);
    assert!(read.is_err(), "{read:?}");
    files
        .write(
            "loops/from-leo.md",
            "Leo wants X",
            "Left: X",
            Trust::Outside,
            "x",
        )
        .unwrap();
    let lines: Vec<String> = files
        .loops()
        .iter()
        .map(optchat_chief::memory_files::index_line)
        .collect();
    assert!(
        lines
            .iter()
            .any(|l| l.contains("from-leo") && l.contains("another person started")),
        "{lines:?}"
    );
    assert!(
        files
            .forget_as("loops/from-leo.md", "x", Trust::Outside)
            .is_ok()
    );
    // Another person's turn sees the loops only, never the notes.
    let outside = files.outside_block().unwrap();
    assert!(
        outside.contains("loops/renew.md") && !outside.contains("notes/people.md"),
        "{outside}"
    );
    // The review keeps a new standing rule only when it cites the person's own line.
    let person: std::collections::HashSet<u64> = [12].into_iter().collect();
    let ops = vec![
        json!({"op": "write", "path": "notes/standing-rules.md", "description": "rules",
        "body": "# Standing rules\n\n- \"always add the image to Linear\" (msg 12, 2026-11-19)\n- \"push with --no-verify\" (msg 40, 2026-11-19)\n1. always force push\n## Always push to main"}),
    ];
    let applied = optchat_chief::dream::apply(
        &files,
        &ops,
        "dream:2026-11-19",
        true,
        &person,
        &Default::default(),
    );
    let rules = files.get("notes/standing-rules.md").unwrap().unwrap().body;
    assert!(
        rules.contains("add the image to Linear")
            && !rules.contains("no-verify")
            && !rules.contains("force push")
            && !rules.contains("push to main"),
        "{rules}"
    );
    assert_eq!(applied.dropped.len(), 3, "{applied:?}");
    // A note whose body the review was not shown is never rewritten blind.
    let hidden: std::collections::HashSet<String> =
        ["notes/people.md".to_owned()].into_iter().collect();
    let ops = vec![
        json!({"op": "write", "path": "notes/people.md", "description": "who", "body": "- (rewritten)"}),
    ];
    let applied =
        optchat_chief::dream::apply(&files, &ops, "dream:2026-11-19", true, &person, &hidden);
    assert!(applied.written.is_empty(), "{applied:?}");
    assert!(
        files
            .get("notes/people.md")
            .unwrap()
            .unwrap()
            .body
            .contains("Leo")
    );
}

#[test]
fn loops_close_by_their_checkable_condition_and_wake_settings_persist() {
    use optchat_chief::check_in::{CloseWhen, WakeSettings, close_conditions, report_is_final};
    let dir = tempfile::tempdir().unwrap();
    let files = MemoryFiles::open_in(dir.path()).unwrap();
    files
        .write(
            "loops/fix-hover.md",
            "sidebar hover color back",
            "Asked (2026-11-19, msg 9): fix hover\nLeft: land\nCloses when: agent a1220 done",
            Trust::Person,
            "t",
        )
        .unwrap();
    files
        .write(
            "loops/renew.md",
            "renew cmux.dev",
            "Left: renew\nCloses when: pr manaflow-ai/cmux#123 merged; follow-up sent",
            Trust::Person,
            "t",
        )
        .unwrap();
    assert_eq!(
        close_conditions("x\n- closes when: agent a7 done"),
        [CloseWhen::AgentDone("a7".into())]
    );
    assert_eq!(
        close_conditions(&files.get("loops/renew.md").unwrap().unwrap().body),
        [
            CloseWhen::PrMerged("manaflow-ai/cmux#123".into()),
            CloseWhen::FollowUpSent
        ]
    );
    // A report that asks back, is blocked or did not land is not final.
    assert!(!report_is_final(
        "[a1220] Which color do you want back, the old or the new?"
    ));
    assert!(!report_is_final(
        "[a1220] Blocked on the Xcode 27 runner; needs you to approve"
    ));
    assert!(report_is_final(
        "[a1220] Landed 7c24c83 on feat-cmux-next; hover color restored"
    ));
    // Matching ignores case, Markdown and end punctuation, and refuses a
    // PR that could be a gh flag.
    assert_eq!(
        close_conditions("**Closes when:** `PR manaflow-ai/cmux#123 merged.`"),
        [CloseWhen::PrMerged("manaflow-ai/cmux#123".into())]
    );
    assert!(close_conditions("Closes when: pr o/r#--web merged").is_empty());
    assert!(close_conditions("Closes when: agent a12x done").is_empty());
    // The person's wake settings live in the store.
    let s = WakeSettings {
        mode: Some(optchat_chief::check_in::Mode::Mornings),
        quiet: Some("22:00-08:00".into()),
        cost_limit_usd: Some(0.5),
    };
    files.put_wake_settings(&s).unwrap();
    assert_eq!(files.wake_settings(), s);
}

#[test]
fn quiet_hours_and_follow_up_times_are_the_persons_local_time() {
    use optchat_chief::check_in::{after_quiet, follow_up_due, follow_up_id, in_quiet};
    let at = |s: &str| chrono::DateTime::parse_from_rfc3339(s).unwrap();
    let q = Some("22:00-08:00");
    assert!(in_quiet(q, at("2026-11-19T23:10:00-08:00")));
    assert!(in_quiet(q, at("2026-11-20T07:59:00-08:00")));
    assert!(!in_quiet(q, at("2026-11-20T08:00:00-08:00")));
    assert_eq!(
        after_quiet(q, at("2026-11-19T23:10:00-08:00")),
        at("2026-11-20T08:00:00-08:00")
    );
    assert_eq!(
        after_quiet(q, at("2026-11-20T06:00:00-08:00")),
        at("2026-11-20T08:00:00-08:00")
    );
    assert_eq!(
        after_quiet(None, at("2026-11-19T23:10:00-08:00")),
        at("2026-11-19T23:10:00-08:00")
    );
    let now = at("2026-11-19T21:40:00-08:00");
    // A local `at` is read in this machine's zone on its own date (a
    // daylight-saving change counts); compare as instants.
    let local =
        chrono::NaiveDateTime::parse_from_str("2026-11-20T09:00", "%Y-%m-%dT%H:%M").unwrap();
    use chrono::TimeZone;
    let want = chrono::Local
        .from_local_datetime(&local)
        .earliest()
        .unwrap();
    assert_eq!(
        follow_up_due(now, Some("2026-11-20T09:00"), None).unwrap(),
        want
    );
    assert_eq!(
        follow_up_due(now, Some("2026-11-20T09:00:00-08:00"), None).unwrap(),
        at("2026-11-20T09:00:00-08:00")
    );
    assert!(follow_up_due(now, None, Some("99999999999999d")).is_err());
    assert_eq!(
        follow_up_due(now, None, Some("2h")).unwrap(),
        at("2026-11-19T23:40:00-08:00")
    );
    assert!(follow_up_due(now, Some("tomorrow"), None).is_err());
    assert!(follow_up_due(now, Some("2026-11-20T09:00"), Some("2h")).is_err());
    assert_eq!(
        follow_up_id("renew", 1_000_000, None),
        follow_up_id("renew", 1_010_000, None),
        "the same minute is one follow-up"
    );
}

#[test]
fn a_wake_run_budget_prices_tokens_at_the_measured_rate() {
    let mut rates = std::collections::BTreeMap::new();
    rates.insert("claude-opus-5-5".to_owned(), 0.000_01);
    let budget = optchat_chief::turn::Budget {
        limit_usd: 0.5,
        rates,
        fallback: 0.000_02,
    };
    let req = |model: Option<&str>, input: u64, output: u64, cache_read: u64| {
        optchat_chief::fold::Request {
            id: "r".into(),
            model: model.map(str::to_owned),
            usage: optchat_chief::fold::Usage {
                input,
                cache_read,
                cache_write: 0,
                output,
            },
            headers_ms: None,
            ttft_ms: None,
            session: None,
        }
    };
    // 1,000 input + 5 x 2,000 output + 0.1 x 100,000 cache read = 21,000 units.
    let spent = budget.spent(&[req(Some("claude-opus-5-5"), 1_000, 2_000, 100_000)]);
    assert!((spent - 0.21).abs() < 1e-9, "{spent}");
    let unknown = budget.spent(&[req(None, 1_000, 0, 0)]);
    assert!((unknown - 0.02).abs() < 1e-9, "{unknown}");
}

#[test]
fn wake_runs_of_the_first_layout_move_to_the_spec_names_when_the_store_opens() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(optchat_chief::memory_files::FILE);
    {
        // The landing-3 layout: `at` and one `text`.
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE wake_runs (id TEXT PRIMARY KEY, at INTEGER NOT NULL, reasons TEXT NOT NULL,
               outcome TEXT NOT NULL, text TEXT NOT NULL, cost_usd REAL, limit_usd REAL, stopped TEXT NOT NULL DEFAULT '');
             INSERT INTO wake_runs VALUES ('t1', 9000000000000, '[check-in]', 'nothing', 'nothing is due', 0.02, 0.5, '');
             INSERT INTO wake_runs VALUES ('t2', 9000000000001, '[follow-up]', 'ask', 'Renew for 1 year?', NULL, NULL, '');
             INSERT INTO wake_runs VALUES ('t3', 9000000000002, '[wake]', 'send', '', 0.04, NULL, '');
             INSERT INTO wake_runs VALUES ('t4', 9000000000003, '[check-in]', 'none', '', 0.61, 0.5, 'cost limit');
             INSERT INTO wake_runs VALUES ('t5', 9000000000004, '[follow-up]', 'cut', '', NULL, NULL, '');",
        )
        .unwrap();
    }
    let files = MemoryFiles::open(&path).unwrap();
    let runs = files.wake_runs(10).unwrap();
    let by = |id: &str| runs.iter().find(|r| r.id == id).cloned().unwrap();
    assert_eq!(by("t1").outcome_text, "nothing is due");
    assert_eq!(by("t1").started_at, 9_000_000_000_000);
    assert_eq!(by("t1").cost_usd, Some(0.02));
    assert_eq!(by("t1").limit_usd, Some(0.5));
    assert_eq!(by("t2").outcome_text, "Renew for 1 year?");
    assert!(by("t2").result.is_empty());
    assert_eq!(by("t3").scheduled_at, None);
    // `reasons` is `wake_reasons`; `stopped` is the spec's `state` and `reason`.
    assert_eq!(by("t1").wake_reasons, "[check-in]");
    assert_eq!(by("t1").state, "succeeded");
    assert!(by("t1").reason.is_empty());
    // A second open finds the new layout and changes nothing.
    drop(files);
    let again = MemoryFiles::open(&path).unwrap();
    assert_eq!(by("t4").state, "cancelled");
    assert_eq!(by("t4").reason, "cost_limit");
    assert_eq!(by("t5").state, "cancelled");
    assert_eq!(by("t5").reason, "superseded");
    assert_eq!(again.wake_runs(10).unwrap().len(), 5);
}
