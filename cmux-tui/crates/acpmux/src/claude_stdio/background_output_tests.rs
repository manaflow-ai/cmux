//! A background shell's output file is known while it runs: Claude Code
//! names it in the launch's tool result ("Output is being written to: …"),
//! long before the task notification, so `acpmux process show` can follow
//! a running task's output, not only replay a finished one.

use super::*;

/// The output files the updates name (`_meta.acpmux.outputFile`), in order.
fn named_files(msgs: &[Message]) -> Vec<String> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Notification { method: m, params: Some(p) } if m == method::SESSION_UPDATE => {
                p.pointer("/_meta/acpmux/outputFile").and_then(Value::as_str).map(str::to_owned)
            }
            _ => None,
        })
        .collect()
}

fn launch() -> Value {
    json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_bg",
        "name": "Bash", "input": {"command": "npm run dev", "run_in_background": true}}]}})
}

fn started() -> Value {
    json!({"type": "system", "subtype": "task_started", "task_id": "b7x", "tool_use_id": "toolu_bg",
        "task_type": "local_bash", "description": "npm run dev", "is_backgrounded": true})
}

fn result(text: &str) -> Value {
    json!({"type": "user", "message": {"content": [{"type": "tool_result",
        "tool_use_id": "toolu_bg", "content": text}]}})
}

const RESULT: &str = "Command running in background with ID: b7x. Output is being written to: \
    /tmp/claude-501/proj/s1/tasks/b7x.output";

#[tokio::test]
async fn the_launch_result_names_a_running_shells_output_file() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&launch()).await;
    assert!(named_files(&t.inbound(&started()).await).is_empty());
    let out = t.inbound(&result(RESULT)).await;
    assert_eq!(named_files(&out), vec!["/tmp/claude-501/proj/s1/tasks/b7x.output".to_owned()]);
}

#[tokio::test]
async fn a_result_before_the_task_starts_names_it_in_the_running_update() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&launch()).await;
    assert!(named_files(&t.inbound(&result(RESULT)).await).is_empty());
    let out = t.inbound(&started()).await;
    assert_eq!(named_files(&out), vec!["/tmp/claude-501/proj/s1/tasks/b7x.output".to_owned()]);
}

#[tokio::test]
async fn a_result_without_a_path_names_nothing() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&launch()).await;
    t.inbound(&started()).await;
    assert!(
        named_files(&t.inbound(&result("Command running in background with ID: b7x.")).await)
            .is_empty()
    );
}

/// The `background_task_update` that says how the shell ended.
fn ended(msgs: &[Message]) -> Option<Value> {
    msgs.iter().find_map(|m| match m {
        Message::Notification { params: Some(p), .. }
            if p.pointer("/update/sessionUpdate") == Some(&json!("background_task_update"))
                && p.pointer("/update/state") != Some(&json!("running")) =>
        {
            Some(p["update"].clone())
        }
        _ => None,
    })
}

fn notification(status: &str, summary: &str) -> Value {
    json!({"type": "system", "subtype": "task_notification", "task_id": "b7x",
        "tool_use_id": "toolu_bg", "status": status, "output_file": "", "summary": summary})
}

/// Claude Code says a background shell's exit code only in its notification's summary; the
/// end's update carries it as `exitCode`, as Codex's does.
#[tokio::test]
async fn a_background_shells_end_carries_the_exit_code_its_summary_names() {
    for (status, summary, state, code) in [
        (
            "completed",
            "Background command \"Run the dev server\" completed (exit code 0)",
            "completed",
            Some(0),
        ),
        (
            "failed",
            "Background command \"Run the bench\" failed with exit code 101",
            "failed",
            Some(101),
        ),
        // A description that says the words is not read as the code.
        (
            "failed",
            "Background command \"check exit code 7\" failed (exit code 2)",
            "failed",
            Some(2),
        ),
        ("killed", "Background command \"npm run dev\" was stopped", "stopped", None),
    ] {
        let t = Translator::new("acp-1".into(), "default", "haiku", "default");
        t.inbound(&launch()).await;
        t.inbound(&started()).await;
        t.inbound(&result(RESULT)).await;
        let end = ended(&t.inbound(&notification(status, summary)).await).expect("an end");
        assert_eq!(end["state"], state, "{end}");
        assert_eq!(end["summary"], summary, "{end}");
        assert_eq!(end.get("exitCode").and_then(Value::as_i64), code, "{end}");
    }
}

#[test]
fn summary_exit_codes() {
    use super::inbound::summary_exit_code;
    assert_eq!(summary_exit_code("x completed (exit code 0)"), Some(0));
    assert_eq!(summary_exit_code("x failed with exit code -1"), Some(-1));
    assert_eq!(summary_exit_code("x failed (exit code )"), None);
    assert_eq!(summary_exit_code("done"), None);
}
