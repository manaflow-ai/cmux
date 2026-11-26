//! What a running subagent does, from its acpmux events (acp-chief-issues.md
//! #4, #5, #6, #13, #16, #20). 77 of the 80 "looks stuck" alerts of
//! 2026-10-19 were agents alive inside `sleep 1500; cmux-ci status ID` or
//! `cmux-ci wait ID`, sending a heartbeat every 30 s; the host only looked
//! at session-summary changes.

use optchat_chief::sub_watch::{
    Alarm, Doing, STALL_AFTER, WAIT_MAX, WaitOn, Watch, is_ack, task_of, wait_on,
};
use serde_json::{Value, json};

const T0: u64 = 1_792_400_000_000;
const MIN: u64 = 60_000;
const JOB: &str = "4ef607bb70ac530208590c72";

fn ev(seq: u64, at: u64, dir: &str, kind: &str, msg: Value) -> cmux_chief::acp::AcpmuxEvent {
    serde_json::from_value(json!({"seq": seq, "at": at, "dir": dir, "kind": kind, "msg": msg}))
        .unwrap()
}

fn update(seq: u64, at: u64, kind: &str, mut update: Value) -> cmux_chief::acp::AcpmuxEvent {
    update["sessionUpdate"] = json!(kind);
    ev(
        seq,
        at,
        "in",
        kind,
        json!({"method": "session/update", "params": {"sessionId": "s1", "update": update}}),
    )
}

fn bash(seq: u64, at: u64, id: &str, command: &str) -> cmux_chief::acp::AcpmuxEvent {
    update(
        seq,
        at,
        "tool_call",
        json!({"toolCallId": id, "title": "Bash", "rawInput": {"command": command}, "_meta": {"claude": {"tool": "Bash"}}}),
    )
}

fn done(seq: u64, at: u64, id: &str, text: &str) -> cmux_chief::acp::AcpmuxEvent {
    update(
        seq,
        at,
        "tool_call_update",
        json!({"toolCallId": id, "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": text}}]}),
    )
}

fn beat(seq: u64, at: u64, id: &str) -> cmux_chief::acp::AcpmuxEvent {
    ev(
        seq,
        at,
        "in",
        "claude.tool_progress",
        json!({"heartbeat": true, "parent_tool_use_id": id, "tool_name": "Bash", "type": "tool_progress"}),
    )
}

fn prompt(seq: u64, at: u64, prompt_id: &str) -> cmux_chief::acp::AcpmuxEvent {
    ev(
        seq,
        at,
        "mux",
        "user_message",
        json!({"promptId": prompt_id}),
    )
}

fn say(seq: u64, at: u64, text: &str) -> cmux_chief::acp::AcpmuxEvent {
    update(
        seq,
        at,
        "agent_message_chunk",
        json!({"content": {"type": "text", "text": text}}),
    )
}

/// A watch of a run that waits on a fleet job for `minutes`, beating every 30 s.
fn waiting(minutes: u64) -> Watch {
    let mut w = Watch::after(0);
    w.apply(&prompt(1, T0, "optchat-sub:a1"));
    w.apply(&bash(
        2,
        T0 + 1000,
        "toolu_1",
        &format!("timeout 1700 ~/.local/bin/cmux-ci wait {JOB} 2>&1 | tail -5"),
    ));
    let mut seq = 3;
    let mut at = T0 + 1000;
    while at < T0 + minutes * MIN {
        at += 30_000;
        w.apply(&beat(seq, at, "toolu_1"));
        seq += 1;
    }
    w
}

#[test]
fn a_fleet_wait_that_beats_is_waiting_not_stuck() {
    // #4: a175, a177, a126, a187, a122, a153, a168, a176 were all this.
    let w = waiting(40);
    let now = T0 + 40 * MIN + 10_000;
    match w.doing(now) {
        Doing::Waiting {
            on, beat_ago_ms, ..
        } => {
            assert_eq!(on, WaitOn::Fleet(JOB.into()));
            assert!(beat_ago_ms.is_some_and(|ms| ms < 60_000));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(w.alarm(now), Alarm::None);
    assert!(w.doing(now).label().contains(&format!("fleet run {JOB}")));
}

#[test]
fn a_run_with_no_event_for_fifteen_minutes_is_stalled() {
    // #5: a hung model request sends nothing at all.
    let mut w = Watch::after(0);
    w.apply(&prompt(1, T0, "optchat-sub:a1"));
    w.apply(&say(2, T0 + MIN, "Reading the code."));
    let now = T0 + MIN + STALL_AFTER.as_millis() as u64 + 1;
    assert!(
        matches!(w.doing(now), Doing::Stalled { .. }),
        "{:?}",
        w.doing(now)
    );
    assert!(matches!(w.alarm(now), Alarm::Stalled { .. }));
    // A heartbeat-sending tool that stopped beating is stalled too.
    let w = waiting(10);
    let now = T0 + 10 * MIN + STALL_AFTER.as_millis() as u64 + 60_000;
    assert!(matches!(w.alarm(now), Alarm::Stalled { .. }));
}

#[test]
fn one_fleet_job_waited_on_past_three_hours_is_overdue() {
    // An agent that loops `sleep 1500; cmux-ci status ID` on one job:
    // each call is short, but the job is waited on across them.
    let mut w = Watch::after(0);
    w.apply(&prompt(1, T0, "optchat-sub:a1"));
    let mut seq = 2;
    let mut at = T0;
    let mut k = 0;
    while at < T0 + WAIT_MAX.as_millis() as u64 + 10 * MIN {
        let id = format!("t{k}");
        w.apply(&bash(
            seq,
            at,
            &id,
            &format!("sleep 1500; ~/.local/bin/cmux-ci status {JOB} | head -2"),
        ));
        seq += 1;
        at += 25 * MIN;
        w.apply(&done(seq, at, &id, "\"state\": \"queued\""));
        seq += 1;
        k += 1;
    }
    w.apply(&bash(
        seq,
        at,
        "last",
        &format!("sleep 1500; cmux-ci status {JOB}"),
    ));
    match w.alarm(at + 30_000) {
        Alarm::Overdue { what, .. } => assert!(what.contains(JOB), "{what}"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_tool_without_heartbeats_is_trusted_until_its_limit() {
    // codex sends nothing while a command runs.
    let mut w = Watch::after(0);
    w.apply(&prompt(1, T0, "optchat-sub:a1"));
    w.apply(&bash(2, T0, "c1", "cargo test --workspace"));
    let now = T0 + 30 * MIN;
    assert!(
        matches!(w.doing(now), Doing::Tool { .. }),
        "{:?}",
        w.doing(now)
    );
    assert_eq!(w.alarm(now), Alarm::None);
    assert!(matches!(w.alarm(T0 + 2 * 60 * MIN), Alarm::Overdue { .. }));
}

#[test]
fn the_summary_names_the_last_line_pushes_and_fleet_runs() {
    // #6 and #13: what a status or a stopped report must say.
    let mut w = Watch::after(0);
    w.apply(&prompt(1, T0, "optchat-sub:a1"));
    w.apply(&say(2, T0 + 1000, "Pushing the fix now."));
    w.apply(&bash(
        3,
        T0 + 2000,
        "p",
        "git push origin HEAD:feat-cmux-next",
    ));
    w.apply(&done(
        4,
        T0 + 3000,
        "p",
        "To github.com:manaflow-ai/cmux.git\n   1a2b3c4d5e..9f8e7d6c5b  HEAD -> feat-cmux-next",
    ));
    w.apply(&bash(
        5,
        T0 + 4000,
        "b",
        "cmux-ci build cmux --ref 9f8e7d6c5b --tag x-v1",
    ));
    w.apply(&done(6, T0 + 5000, "b", &format!("submitted job {JOB}")));
    let lines = w.summary(T0 + 6000).join("\n");
    assert!(lines.contains("last said: Pushing the fix now."), "{lines}");
    assert!(
        lines.contains("pushed: 1a2b3c4d5e..9f8e7d6c5b -> feat-cmux-next"),
        "{lines}"
    );
    assert!(lines.contains(&format!("fleet runs: {JOB}")), "{lines}");
    assert_eq!(w.pushed().len(), 1);
}

#[test]
fn a_continue_says_which_fleet_runs_to_wait_on_again() {
    // #16: a121's runs were cancelled and run again after each restart.
    let w = waiting(20);
    let note = w.resume_note(T0 + 20 * MIN);
    assert!(note.contains("git status"), "{note}");
    assert!(note.contains(JOB), "{note}");
    assert!(note.contains("do not submit them again"), "{note}");
}

#[test]
fn waits_are_told_from_work() {
    assert_eq!(
        wait_on(&format!(
            "timeout 1500 ~/.local/bin/cmux-ci wait {JOB} 2>&1 | tail -3"
        )),
        Some(WaitOn::Fleet(JOB.into()))
    );
    assert_eq!(
        wait_on("sleep 1500; gh run view 39355579856 --repo manaflow-ai/cmux --json status"),
        Some(WaitOn::GhRun("39355579856".into()))
    );
    assert_eq!(
        wait_on("until grep -q '^exit=' /tmp/divider-red.log; do sleep 30; done"),
        Some(WaitOn::Poll)
    );
    assert_eq!(wait_on("cargo test -p optchat-chief"), None);
    assert_eq!(wait_on("git log --oneline high gh"), None);
}

#[test]
fn a_task_is_what_follows_the_view() {
    // #6: status showed "<chat> 0+128|user: ..." as the last prompt.
    let prompt =
        "<chat>\n0+128|user: hi\n</chat>Your task:\n\nACP status and stuck detection\n\nFix it.";
    assert_eq!(
        task_of(prompt).as_deref(),
        Some("ACP status and stuck detection\n\nFix it.")
    );
    assert_eq!(task_of("<chat>\n0+1|user: hi\n</chat>"), None);
}

#[test]
fn acks_are_quiet_and_reports_are_not() {
    // #20: a164 "Understood ... I'm stopping now", a137's rename notes.
    assert!(is_ack(
        "Understood: a145 handles the settings exports, Routines and the chips wait, and no more force pushes. I'm stopping now."
    ));
    assert!(is_ack(
        "I renamed a199 to \"a199 · Pre-push quality gate\" and put it in \"Nightly & CI\"."
    ));
    assert!(!is_ack("Done: pushed 653c50a0595 to feat-cmux-next."));
    assert!(!is_ack("Understood, but the build failed on cmux10s."));
    assert!(!is_ack("Understood. Reply `keep` or `drop`?"));
    assert!(!is_ack("(stopped by the user)"));
}
