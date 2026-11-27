use super::*;

#[test]
fn adopted_test_update_keeps_reproducible_alarm_with_its_settled_diff() {
    let changes = json!({"suite.test.ts":{"type":"update","unified_diff":"@@ -42,1 +42,1 @@\n-expect(count).toEqual(3);\n+expect(count).toBeTruthy();\n"}});
    let tool = codex_file_change("edit-1", &changes, "completed", None, Some(9)).unwrap();
    assert!(tool.call.get("tampering").is_none());
    assert_eq!(tool.done["content"][0]["line"], 42);
    let report = tool.done.get("tampering").expect("weakened assertion alarm");
    assert_eq!(report, &crate::test_tampering::detect_diffs(&tool.done["content"]).unwrap());
    assert_eq!(report["files"][0]["findings"][0]["line"], 42);
    assert_eq!(report["files"][0]["findings"][0]["kind"], "weakened-assertion");
}

#[test]
fn adopted_test_deletion_is_detected_from_whole_file_content() {
    let changes = json!({"tests/check.rs":{"type":"delete","content":"#[test]\nfn checks() { assert_eq!(count(), 3); }\n"}});
    let tool = codex_file_change("delete-1", &changes, "completed", None, None).unwrap();
    let report = tool.done.get("tampering").expect("removed test alarm");
    assert_eq!(report, &crate::test_tampering::detect_diffs(&tool.done["content"]).unwrap());
    assert_eq!(report["files"][0]["findings"][0]["kind"], "removed-test");
    assert_eq!(tool.done["content"][0]["line"], 1);
}

#[test]
fn failed_or_normal_adopted_edits_have_no_alarm() {
    let stronger = json!({"suite.test.ts":{"type":"update","unified_diff":"@@ -1 +1 @@\n-expect(count).toBeTruthy();\n+expect(count).toEqual(3);\n"}});
    let normal = codex_file_change("stronger", &stronger, "completed", None, None).unwrap();
    assert!(normal.done.get("tampering").is_none());
    assert!(crate::test_tampering::detect_diffs(&normal.done["content"]).is_none());
    let weakened = json!({"suite.test.ts":{"type":"update","unified_diff":"@@ -1 +1 @@\n-expect(count).toEqual(3);\n+expect(count).toBeTruthy();\n"}});
    let failed =
        codex_file_change("failed", &weakened, "failed", Some("not applied"), None).unwrap();
    assert!(failed.call.get("tampering").is_none());
    assert!(failed.done.get("tampering").is_none());
    assert!(crate::test_tampering::detect_diffs(&failed.done["content"]).is_none());
}

#[test]
fn adopted_claude_alarm_waits_for_confirmed_edit_and_shares_its_evidence() {
    let edit = json!([{"type":"tool_use", "id":"test-edit", "name":"Edit", "input":{
        "file_path":"/p/suite.test.ts", "old_string":"expect(count).toEqual(3);", "new_string":"expect(count).toBeTruthy();"
    }}]);
    let mut tool = claude_tool_uses(&edit, Some(1)).remove(0);
    assert!(tool.call.get("tampering").is_none());
    assert!(tool.done.get("tampering").is_none());
    tool.settle(&result("test-edit", false), Some(2));
    let report = tool.done.get("tampering").expect("settled edit alarm");
    assert_eq!(report, &crate::test_tampering::detect_diffs(&tool.done["content"]).unwrap());
    let mut failed = claude_tool_uses(&edit, Some(1)).remove(0);
    failed.settle(&result("test-edit", true), Some(2));
    assert!(failed.done.get("tampering").is_none());
}

 #[test]
#[test]
fn a_codex_read_parsed_from_a_loop_never_titles_its_shell_variable() {
    let item = json!({
        "command": ["/bin/zsh", "-lc", "for f in a.md b.md; do cat $f; done"],
        "parsed_cmd": [{"type": "read", "cmd": "cat $f", "name": "$f", "path": "$f"}],
        "aggregated_output": "x", "exit_code": 0, "status": "completed",
    });
    let tool = codex_command("c1", &item, None).unwrap();
    assert_eq!(tool.call["kind"], "execute");
    assert_eq!(tool.call["title"], "for f in a.md b.md; do cat $f; done");
    assert!(tool.call.get("locations").is_none());
    let plain = json!({"command": "cat a.md", "parsed_cmd": [{"type": "read", "name": "a.md", "path": "a.md"}]});
    assert_eq!(codex_command("c2", &plain, None).unwrap().call["title"], "Read a.md");
}

#[test]
fn pleasant_tool_labels_replay_codex_exec_and_mcp() {
    let item = json!({"command": ["sh", "-c", "ls -l"], "description": " List build artifacts "});
    let exec = codex_command("c1", &item, None).unwrap();
    assert_eq!(exec.call["title"], "List build artifacts");
    assert_eq!(exec.call["rawInput"]["command"], "ls -l");
    assert_eq!(exec.call["rawInput"]["description"], "List build artifacts");

    let item = json!({"server": "repo", "tool": "search", "arguments": {"query": "TODO", "description": "Find follow-ups"}});
    let mcp = codex_mcp("c2", &item, None);
    assert_eq!(mcp.call["rawInput"], item);
}

fn edit(id: &str) -> Value {
    json!([{"type": "tool_use", "id": id, "name": "Edit",
            "input": {"file_path": "/p/src/lib.rs", "old_string": "a", "new_string": "b"}}])
}

fn result(id: &str, is_error: bool) -> ToolResult {
    let block =
        json!([{"type": "tool_result", "tool_use_id": id, "content": "ok", "is_error": is_error}]);
    claude_tool_results(&block, None).remove(0)
}

/// A Claude Code edit shows its diff only once a result that did not fail confirms it: one
/// cut off before its result, or refused, changed nothing and counts no edited file.
#[test]
fn a_claude_edit_shows_its_diff_only_when_its_result_confirms_it() {
    let [cut_off] = claude_tool_uses(&edit("t1"), Some(1)).try_into().unwrap();
    assert_eq!(cut_off.done, json!({"status": "failed"}));

    let [mut refused] = claude_tool_uses(&edit("t2"), Some(1)).try_into().unwrap();
    refused.settle(&result("t2", true), Some(2));
    assert_eq!(refused.done["status"], "failed");
    assert_eq!(refused.done["content"], json!([text_content("ok")]));

    let [mut applied] = claude_tool_uses(&edit("t3"), Some(1)).try_into().unwrap();
    applied.settle(&result("t3", false), Some(2));
    assert_eq!(applied.done["status"], "completed");
    assert_eq!(applied.done["content"][0]["type"], "diff", "{}", applied.done);
    assert_eq!(applied.done["content"][0]["newText"], "b");
}

/// An adopted Read of an image keeps the image its result returned, so a reopened chat on
/// another machine draws it instead of "Image unavailable".
#[test]
fn an_adopted_claude_read_keeps_the_image_its_result_returned() {
    let read = json!([{"type": "tool_use", "id": "r1", "name": "Read",
                       "input": {"file_path": "/tmp/shot.png"}}]);
    let [mut tool] = claude_tool_uses(&read, Some(1)).try_into().unwrap();
    let block = json!([{"type": "tool_result", "tool_use_id": "r1", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0K"}}]}]);
    let [result] = claude_tool_results(&block, None).try_into().unwrap();
    tool.settle(&result, Some(2));
    assert_eq!(tool.done["status"], "completed");
    assert_eq!(
        tool.done["content"],
        json!([{"type": "content", "content": {"type": "image", "mimeType": "image/png", "data": "iVBORw0K"}}])
    );
}

fn write(id: &str) -> Value {
    json!([{"type": "tool_use", "id": id, "name": "Write",
            "input": {"file_path": "/p/notes.md", "content": "new\n"}}])
}

/// An adopted Write as the transcript line records it: the tool_result and, beside the
/// message, `toolUseResult`.
fn write_settled(id: &str, text: &str, structured: Option<Value>) -> Value {
    let [mut tool] = claude_tool_uses(&write(id), Some(1)).try_into().unwrap();
    let block = json!([{"type": "tool_result", "tool_use_id": id, "content": text}]);
    let [result] = claude_tool_results(&block, structured.as_ref()).try_into().unwrap();
    tool.settle(&result, Some(2));
    assert_eq!(tool.done["status"], "completed");
    tool.done["content"][0].clone()
}

/// An adopted Claude Write reads as a new file (which Undo may trash) only when its result
/// says it created the file; over a file that was there it carries the old text, or stays a
/// fragment, so Undo never trashes an overwritten file.
#[test]
fn an_adopted_claude_write_is_new_only_when_its_result_says_it_created_the_file() {
    let fragment = |diff: &Value| diff.pointer("/_meta/acpmux/fragment") == Some(&json!(true));

    let created = json!({"type": "create", "filePath": "/p/notes.md", "originalFile": null});
    let diff = write_settled("w1", "File created successfully at: /p/notes.md", Some(created));
    assert_eq!(diff["oldText"], Value::Null);
    assert!(!fragment(&diff), "{diff}");

    let updated = json!({"type": "update", "filePath": "/p/notes.md", "originalFile": "old\n"});
    let diff = write_settled("w2", "The file /p/notes.md has been updated.", Some(updated));
    assert_eq!(diff["oldText"], "old\n");
    assert!(!fragment(&diff), "{diff}");

    let diff = write_settled("w3", "The file /p/notes.md has been updated.", None);
    assert_eq!(diff["oldText"], Value::Null);
    assert!(fragment(&diff), "{diff}");

    // Cut off before its result: no diff at all, as for any edit.
    let [cut_off] = claude_tool_uses(&write("w4"), Some(1)).try_into().unwrap();
    assert_eq!(cut_off.done, json!({"status": "failed"}));
}
