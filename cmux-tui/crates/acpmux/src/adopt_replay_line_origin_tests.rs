use super::*;
use serde_json::json;

fn of(record: Value) -> LineOrigin {
    line_origin(&record)
}

#[test]
fn origin_decides_never_the_text() {
    // A notification's text on a human line is the person's; a person's words under a
    // task-notification origin are the harness's.
    let text = "<task-notification><summary>Subagent disconnected</summary></task-notification>";
    assert_eq!(of(json!({"message": {"content": text}})), LineOrigin::Person);
    assert_eq!(
        of(json!({"origin": {"kind": "human"}, "message": {"content": text}})),
        LineOrigin::Person
    );
    assert_eq!(
        of(json!({"origin": {"kind": "task-notification"}, "message": {"content": "fix it"}})),
        LineOrigin::TaskNotification
    );
    assert_eq!(of(json!({"origin": {"kind": "peer"}})), LineOrigin::Peer);
    assert_eq!(of(json!({"origin": {"kind": "channel"}})), LineOrigin::Other);
    assert_eq!(of(json!({"origin": null})), LineOrigin::Person);
}

#[test]
fn harness_lines_are_tool_like_and_never_the_person() {
    for kind in ["task-notification", "peer"] {
        let record = json!({"origin": {"kind": kind}});
        assert!(line_origin(&record).is_tool_like());
        assert!(!from_person(&record));
    }
    assert!(!LineOrigin::Person.is_tool_like());
    assert!(!LineOrigin::Other.is_tool_like());
    assert!(!from_person(&json!({"origin": {"kind": "channel"}})));
}

fn fold(tools: bool, lines: &[Value]) -> Vec<PastTurn> {
    let mut fold = Fold::new("claude", tools);
    for line in lines {
        fold.line(line.to_string().as_bytes());
    }
    fold.finish()
}

fn transcript() -> Vec<Value> {
    let note = "<task-notification><task-id>a1</task-id><status>completed</status><summary>Agent \"lint\" completed</summary></task-notification>";
    let peer =
        "<cross-session-message from=\"s2\" name=\"coord\">Merged #1</cross-session-message>";
    vec![
        json!({"type": "user", "timestamp": "2026-11-24T01:00:00Z", "message": {"content": "Land the lanes"}}),
        json!({"type": "assistant", "timestamp": "2026-11-24T01:00:01Z", "message": {"content": [{"type": "tool_use", "id": "c1", "name": "Bash", "input": {"command": "ls"}}]}}),
        json!({"type": "user", "timestamp": "2026-11-24T01:00:02Z", "origin": {"kind": "task-notification"}, "message": {"content": note}}),
        json!({"type": "user", "timestamp": "2026-11-24T01:00:03Z", "isMeta": true, "origin": {"kind": "peer"}, "message": {"content": [{"type": "text", "text": peer}]}}),
        json!({"type": "user", "timestamp": "2026-11-24T01:00:04Z", "origin": {"kind": "channel"}, "message": {"content": "not ours"}}),
        json!({"type": "assistant", "timestamp": "2026-11-24T01:00:05Z", "message": {"content": [{"type": "text", "text": "Done."}], "stop_reason": "end_turn"}}),
    ]
}

#[test]
fn a_replay_keeps_harness_lines_in_their_turn_with_their_origin() {
    let turns = fold(true, &transcript());
    assert_eq!(turns.len(), 1, "a harness line opens no turn");
    let turn = &turns[0];
    assert_eq!(turn.prompt, "Land the lanes");
    assert_eq!(turn.answer, "Done.");
    let kept: Vec<_> = turn.harness.iter().map(|h| (h.origin, h.after_tools)).collect();
    assert_eq!(kept, [(LineOrigin::TaskNotification, 1), (LineOrigin::Peer, 1)]);
    assert!(turn.harness[0].text.starts_with("<task-notification>"));
    assert!(turn.harness[1].text.contains("Merged #1"));
    assert!(turn.harness[0].at.is_some());
}

#[test]
fn the_chats_page_and_a_page_before_any_prompt_leave_harness_lines_out() {
    assert!(fold(false, &transcript())[0].harness.is_empty());
    // A page that starts after the prompt has no turn for the line to join.
    // (`finish` keeps no turn at all then: the answer has none to join either.)
    assert!(fold(true, &transcript()[2..]).iter().all(|t| t.harness.is_empty()));
}

#[test]
fn a_watched_transcript_reads_harness_lines_as_their_own_step() {
    let mut codex = false;
    let steps = record_steps("claude", &transcript()[2], &mut codex);
    assert!(matches!(&steps[..], [Step::Harness(LineOrigin::TaskNotification, _)]));
    assert!(record_steps("claude", &transcript()[4], &mut codex).is_empty());
}

#[test]
fn a_logged_harness_row_is_known_by_its_mark() {
    assert!(harness_row(&json!({"text": "x", "_meta": {"lineOrigin": "task-notification"}})));
    assert!(harness_row(&json!({"_meta": {"lineOrigin": "peer"}})));
    assert!(!harness_row(&json!({"_meta": {"lineOrigin": "person"}})));
    assert!(!harness_row(&json!({"text": "<task-notification></task-notification>"})));
    assert_eq!(LineOrigin::TaskNotification.wire(), "task-notification");
    assert_eq!(LineOrigin::Peer.wire(), "peer");
}
