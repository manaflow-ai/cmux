use super::*;
use serde_json::json;

#[test]
fn an_agent_question_is_never_notified_as_a_permission() {
    let normalized = json!({"toolCall": {"title": "AskUserQuestion", "_meta": {
        "claude": {"tool": "AskUserQuestion"},
        "acpmux": {"question": {"items": [{"id": "q0", "prompt": "Which database?"}]}},
    }}});
    assert_eq!(permission_text("lane", &normalized), "lane asks: Which database?");
    let raw = json!({"toolCall": {"title": "AskUserQuestion",
        "_meta": {"claude": {"tool": "AskUserQuestion"}},
        "rawInput": {"questions": [{"question": "Ship it?"}]}}});
    assert_eq!(permission_text("lane", &raw), "lane asks: Ship it?");
    let bare = json!({"toolCall": {"title": "AskUserQuestion", "_meta": {"claude": {"tool": "AskUserQuestion"}}}});
    assert_eq!(permission_text("lane", &bare), "lane asks a question");
}

#[test]
fn a_tool_permission_still_names_its_tool() {
    let bash = json!({"toolCall": {"title": "Run tests", "kind": "execute"}});
    assert_eq!(permission_text("lane", &bash), "lane needs a permission: Run tests");
    assert_eq!(permission_text("lane", &json!({})), "lane needs a permission: tool");
}
