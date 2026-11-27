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
