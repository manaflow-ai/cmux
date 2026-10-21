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

/// A Write's result line as Claude Code sends it: the tool_result text and,
/// beside the message, `tool_use_result` (`type` create or update, and the
/// file's `originalFile` before an update).
fn write_result(id: &str, text: &str, tool_use_result: Option<Value>) -> Value {
    let mut line = tool_result(id, false, text);
    if let Some(result) = tool_use_result {
        line["tool_use_result"] = result;
    }
    line
}

async fn finished_write(result: Value) -> Value {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let input = json!({"file_path": "/repo/notes.md", "content": "new\n"});
    t.inbound(&tool_use("toolu_1", "Write", input)).await;
    let out = updates(&t.inbound(&result).await);
    assert_eq!(out[0]["status"], "completed", "{out:?}");
    out[0]["content"].clone()
}

// Undo trashes a file whose diff has no old text (the turn created it). A
// Write over a file that was there must not read that way: its completion
// carries the file's text before the Write, or says the diff is a fragment.
#[tokio::test]
async fn claude_edit_write_over_a_file_completes_with_its_old_text() {
    let result = json!({"type": "update", "filePath": "/repo/notes.md", "content": "new\n", "originalFile": "old\n"});
    let content = finished_write(write_result(
        "toolu_1",
        "The file /repo/notes.md has been updated. Here's the result of running `cat -n`:",
        Some(result),
    ))
    .await;
    assert_eq!(
        content,
        json!([{"type": "diff", "path": "/repo/notes.md", "oldText": "old\n", "newText": "new\n"}])
    );
}

#[tokio::test]
async fn claude_edit_write_over_a_file_without_its_old_text_is_a_fragment() {
    let content =
        finished_write(write_result("toolu_1", "The file /repo/notes.md has been updated.", None))
            .await;
    assert_eq!(
        content,
        json!([{"type": "diff", "path": "/repo/notes.md", "oldText": null, "newText": "new\n",
            "_meta": {"acpmux": {"fragment": true}}}])
    );
}

#[tokio::test]
async fn claude_edit_write_that_created_its_file_completes_as_a_new_file() {
    let new_file =
        json!([{"type": "diff", "path": "/repo/notes.md", "oldText": null, "newText": "new\n"}]);
    let created = json!({"type": "create", "filePath": "/repo/notes.md", "content": "new\n", "originalFile": null});
    let text = "File created successfully at: /repo/notes.md";
    assert_eq!(finished_write(write_result("toolu_1", text, Some(created))).await, new_file);
    // Without the structured result, its text says so.
    assert_eq!(finished_write(write_result("toolu_1", text, None)).await, new_file);
}

// A result for another file (two results in one line) does not lend its old text.
#[tokio::test]
async fn claude_edit_write_ignores_another_files_result() {
    let other = json!({"type": "update", "filePath": "/repo/other.md", "originalFile": "other\n"});
    let content = finished_write(write_result(
        "toolu_1",
        "The file /repo/notes.md has been updated.",
        Some(other),
    ))
    .await;
    assert_eq!(content[0]["oldText"], Value::Null);
    assert_eq!(content[0]["_meta"]["acpmux"]["fragment"], true);
}
