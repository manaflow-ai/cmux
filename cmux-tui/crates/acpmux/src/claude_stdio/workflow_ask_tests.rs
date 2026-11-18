//! A Workflow call's permission ask names the run it starts: the workflow's
//! name, description and phase titles from its script's `meta` literal
//! (`workflow_ask.rs`), so the pane's approval card shows them before the
//! person answers Claude's own ask.

use super::workflow_ask::{meta_literal, parse_meta, workflow_ask};
use super::*;

const SCRIPT: &str = r#"export const meta = {
  name: 'review-changes',
  description: "Review changed files, then verify each finding",
  // A comment with a { brace } and a 'quote
  phases: [
    { title: 'Review', detail: 'one agent per {dimension}' },
    { "title": "Verify" },
    { title: `Report` },
  ],
}
const helper = { name: 'not-meta' }
"#;

#[test]
fn the_meta_literal_gives_name_description_and_phases() {
    let meta = parse_meta(meta_literal(SCRIPT).expect("a meta literal"));
    assert_eq!(meta.name.as_deref(), Some("review-changes"));
    assert_eq!(meta.description.as_deref(), Some("Review changed files, then verify each finding"));
    assert_eq!(meta.phases, ["Review", "Verify", "Report"]);
}

#[test]
fn a_nested_name_is_not_the_workflows_and_a_template_is_no_literal() {
    let meta = parse_meta("{ phases: [{ title: `${x} phase`, name: 'inner' }, { title: 'B' }] }");
    assert_eq!(meta.name, None);
    assert_eq!(meta.phases, ["B"]);
    assert_eq!(meta_literal("const other = 1"), None);
    // An unclosed literal is no meta, never a panic.
    assert_eq!(meta_literal("export const meta = { name: 'x', phases: ["), None);
}

#[tokio::test]
async fn an_inline_script_a_path_and_a_saved_name_are_each_read() {
    let inline = workflow_ask(&json!({"script": SCRIPT}), None).await.unwrap();
    assert_eq!(inline["name"], "review-changes");
    assert_eq!(inline["phases"], json!(["Review", "Verify", "Report"]));

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("wf.js");
    std::fs::write(&path, SCRIPT).unwrap();
    let by_path = workflow_ask(&json!({"scriptPath": path}), None).await.unwrap();
    assert_eq!(by_path["phases"], json!(["Review", "Verify", "Report"]));

    let saved = dir.path().join(".claude/workflows");
    std::fs::create_dir_all(&saved).unwrap();
    std::fs::write(saved.join("triage.js"), SCRIPT).unwrap();
    let named = workflow_ask(&json!({"name": "triage"}), Some(dir.path())).await.unwrap();
    assert_eq!(named["description"], "Review changed files, then verify each finding");
    // A name never reaches outside the workflows folder.
    let escape = workflow_ask(&json!({"name": "../wf"}), Some(dir.path())).await.unwrap();
    assert_eq!(escape["phases"], json!([]));
    assert_eq!(escape["name"], "../wf");
}

#[tokio::test]
async fn a_name_with_no_script_or_a_resume_is_named_alone() {
    let built_in = workflow_ask(&json!({"name": "deep-review"}), None).await.unwrap();
    assert_eq!(built_in, json!({"name": "deep-review", "phases": []}));
    let resume = workflow_ask(&json!({"resumeFromRunId": "wf_abc123"}), None).await.unwrap();
    assert_eq!(resume["resume"], "wf_abc123");
    assert_eq!(workflow_ask(&json!({"args": {"x": 1}}), None).await, None);
}

#[tokio::test]
async fn the_workflow_permission_request_carries_the_run() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let ask = json!({"type": "control_request", "request_id": "r1", "request": {
        "subtype": "can_use_tool", "tool_name": "Workflow", "tool_use_id": "toolu_9",
        "input": {"script": SCRIPT}
    }});
    let call = t
        .inbound(&ask)
        .await
        .into_iter()
        .find_map(|m| match m {
            Message::Request { method: m, params: Some(p), .. }
                if m == method::SESSION_REQUEST_PERMISSION =>
            {
                Some(p["toolCall"].clone())
            }
            _ => None,
        })
        .expect("a permission request");
    assert_eq!(call["_meta"]["claude"]["tool"], "Workflow");
    assert_eq!(call["_meta"]["claude"]["workflow"]["name"], "review-changes");
    assert_eq!(
        call["_meta"]["claude"]["workflow"]["phases"],
        json!(["Review", "Verify", "Report"])
    );
}

/// Review of #46229: a quote in a comment opens no string, and `const metaData` is not `meta`.
#[test]
fn comments_and_a_longer_name_do_not_mislead_the_parser() {
    let script = "const metaData = { name: 'wrong' }\nexport const meta = {\n  // don't: name: 'commented'\n  name: 'right', /* phases: [{ title: 'no' }] */\n  phases: [{ title: 'A' }],\n}";
    let meta = parse_meta(meta_literal(script).expect("a meta literal"));
    assert_eq!(meta.name.as_deref(), Some("right"));
    assert_eq!(meta.phases, ["A"]);
}

/// Review of #46229: a device or FIFO the model names is never read (its size reads 0), and a
/// relative path is the chat folder's.
#[cfg(unix)]
#[tokio::test]
async fn a_device_is_never_read_and_a_relative_path_is_the_chats() {
    let zero = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        workflow_ask(&json!({"scriptPath": "/dev/zero", "name": "z"}), None),
    )
    .await
    .expect("answers at once");
    assert_eq!(zero.unwrap()["phases"], json!([]));
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("wf.js"), SCRIPT).unwrap();
    let relative = workflow_ask(&json!({"scriptPath": "wf.js"}), Some(dir.path())).await.unwrap();
    assert_eq!(relative["phases"], json!(["Review", "Verify", "Report"]));
}
