//! A Stop hook's block, as Claude Code sends it, becomes one `hook_feedback` update (`hook_feedback.rs`).

use super::*;

fn synthetic(content: Value) -> Value {
    json!({"type": "user", "session_id": "s", "parent_tool_use_id": null, "isSynthetic": true,
        "message": {"role": "user", "content": content}})
}

fn updates(out: &[Message]) -> Vec<Value> {
    out.iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => {
                params.as_ref().and_then(|p| p.get("update")).cloned()
            }
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn a_blocking_stop_hook_is_one_hook_feedback_update() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = synthetic(
        json!([{"type": "text", "text": "Stop hook feedback:\nSave one note before you stop."}]),
    );
    assert_eq!(
        updates(&t.inbound(&line).await),
        [
            json!({"sessionUpdate": "hook_feedback", "hookEvent": "Stop", "text": "Save one note before you stop."})
        ]
    );
}

#[tokio::test]
async fn a_named_hook_keeps_its_name() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = synthetic(json!("SubagentStop hook feedback:\n[~/bin/check]: Run the tests first."));
    assert_eq!(
        updates(&t.inbound(&line).await),
        [
            json!({"sessionUpdate": "hook_feedback", "hookEvent": "SubagentStop", "hookName": "~/bin/check", "text": "Run the tests first."})
        ]
    );
}

#[tokio::test]
async fn other_synthetic_and_typed_lines_are_not_hook_feedback() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    for line in [
        synthetic(json!("hook text")),
        synthetic(json!("PreToolUse hook feedback:\nno")),
        json!({"type": "user", "message": {"role": "user", "content": "Stop hook feedback:\nI typed this"}}),
    ] {
        let out = t.inbound(&line).await;
        assert!(
            !updates(&out).iter().any(|u| u["sessionUpdate"] == "hook_feedback"),
            "{line}: {out:?}"
        );
    }
}
