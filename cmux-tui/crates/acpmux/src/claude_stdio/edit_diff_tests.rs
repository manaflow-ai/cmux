//! Claude's file edits reach the client as ACP diffs: the tool call, its
//! permission request and its completion carry `diff` content and the file's
//! location, so a client can show what changed and open the turn's changes.

use super::*;

fn updates(msgs: &[Message]) -> Vec<Value> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Notification { method: m, params: Some(p) } if m == method::SESSION_UPDATE => {
                Some(p["update"].clone())
            }
            _ => None,
        })
        .collect()
}

fn tool_use(id: &str, name: &str, input: Value) -> Value {
    json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": id, "name": name, "input": input}]}})
}

fn tool_result(id: &str, is_error: bool, text: &str) -> Value {
    json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": id, "is_error": is_error, "content": text}]}})
}

fn edit_input() -> Value {
    json!({"file_path": "/repo/src/lib.rs", "old_string": "fn a() {}", "new_string": "fn b() {}"})
}

fn edit_diff() -> Value {
    json!([{"type": "diff", "path": "/repo/src/lib.rs", "oldText": "fn a() {}", "newText": "fn b() {}"}])
}

#[tokio::test]
async fn claude_edit_tool_call_carries_its_diff() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let out = updates(&t.inbound(&tool_use("toolu_1", "Edit", edit_input())).await);
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0]["kind"], "edit");
    assert_eq!(out[0]["content"], edit_diff());
    assert_eq!(out[0]["locations"], json!([{"path": "/repo/src/lib.rs"}]));
}

#[tokio::test]
async fn claude_edit_diff_survives_the_tools_completion() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&tool_use("toolu_1", "Edit", edit_input())).await;
    let out =
        updates(&t.inbound(&tool_result("toolu_1", false, "The file has been updated.")).await);
    assert_eq!(out.len(), 1, "{out:?}");
    assert_eq!(out[0]["status"], "completed");
    assert_eq!(out[0]["content"], edit_diff());
}

#[tokio::test]
async fn claude_edit_that_fails_reports_why() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&tool_use("toolu_1", "Edit", edit_input())).await;
    let out =
        updates(&t.inbound(&tool_result("toolu_1", true, "String to replace not found")).await);
    assert_eq!(out[0]["status"], "failed");
    assert_eq!(
        out[0]["content"],
        json!([{"type": "content", "content": {"type": "text", "text": "String to replace not found"}}])
    );
}

#[tokio::test]
async fn claude_edit_multiedit_is_one_diff_per_edit() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let input = json!({"file_path": "/repo/a.rs", "edits": [
        {"old_string": "one", "new_string": "1"},
        {"old_string": "two", "new_string": "2"},
    ]});
    let out = updates(&t.inbound(&tool_use("toolu_1", "MultiEdit", input)).await);
    assert_eq!(
        out[0]["content"],
        json!([
            {"type": "diff", "path": "/repo/a.rs", "oldText": "one", "newText": "1"},
            {"type": "diff", "path": "/repo/a.rs", "oldText": "two", "newText": "2"},
        ])
    );
}

#[tokio::test]
async fn claude_edit_write_is_a_whole_file_diff() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let input = json!({"file_path": "/repo/new.md", "content": "# New\n"});
    let out = updates(&t.inbound(&tool_use("toolu_1", "Write", input)).await);
    assert_eq!(
        out[0]["content"],
        json!([{"type": "diff", "path": "/repo/new.md", "oldText": null, "newText": "# New\n"}])
    );
}

#[tokio::test]
async fn claude_edit_permission_request_shows_the_diff() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let ask = json!({"type": "control_request", "request_id": "r1", "request": {
        "subtype": "can_use_tool", "tool_name": "Edit", "tool_use_id": "toolu_1", "input": edit_input()
    }});
    let out = t.inbound(&ask).await;
    let call = out
        .iter()
        .find_map(|m| match m {
            Message::Request { method: m, params: Some(p), .. }
                if m == method::SESSION_REQUEST_PERMISSION =>
            {
                Some(p["toolCall"].clone())
            }
            _ => None,
        })
        .expect("a permission request");
    assert_eq!(call["content"], edit_diff());
    assert_eq!(call["locations"], json!([{"path": "/repo/src/lib.rs"}]));
}
