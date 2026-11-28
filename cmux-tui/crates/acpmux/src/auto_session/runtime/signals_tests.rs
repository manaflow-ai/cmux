use serde_json::json;

use super::*;

#[test]
fn a_tool_call_names_what_runs_and_its_end() {
    let running = json!({"params": {"update": {
        "sessionUpdate": "tool_call", "toolCallId": "t1", "status": "in_progress",
        "title": "Bash", "rawInput": {"command": "make test"},
    }}});
    assert_eq!(
        tool(&running),
        Signal::ToolStarted(OpenTool {
            name: "Bash".into(),
            args: r#"{"command":"make test"}"#.into()
        })
    );
    let done = json!({"params": {"update": {"toolCallId": "t1", "status": "completed"}}});
    assert_eq!(tool(&done), Signal::ToolEnded);
    let failed = json!({"params": {"update": {"toolCallId": "t1", "status": "failed"}}});
    assert_eq!(tool(&failed), Signal::ToolEnded);
    // An update that names nothing is the agent still at work.
    let nameless = json!({"params": {"update": {"toolCallId": "t1"}}});
    assert_eq!(tool(&nameless), Signal::Streaming);
}

#[test]
fn long_arguments_are_cut_on_a_character() {
    let text = "é".repeat(TOOL_ARGS_MAX);
    let cut = cut(text);
    assert!(cut.len() <= TOOL_ARGS_MAX);
    assert!(cut.chars().all(|c| c == 'é'));
}
