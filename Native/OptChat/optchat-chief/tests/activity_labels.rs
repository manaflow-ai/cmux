//! The live "working on" line (`run.activity`) Home shows above the typing dots:
//! readable words for the Chief's own MCP tools and for described shell calls,
//! and one start time per tool call while its input streams in.

use optchat_chief::run::{RunSteps, activity_line};
use serde_json::json;

#[test]
fn the_chiefs_own_tools_read_as_what_they_do() {
    let tell = json!({"title": "mcp__optchat__tell", "rawInput": {"id": "a31", "message": "hi"}});
    assert_eq!(activity_line("mcp__optchat__tell", &tell), "Telling a31");
    let spawn = json!({"rawInput": {"tasks": ["a", "b"]}});
    assert_eq!(
        activity_line("mcp__optchat__spawn", &spawn),
        "Starting 2 agents"
    );
    assert_eq!(
        activity_line("mcp__optchat__spawn", &json!({})),
        "Starting agents"
    );
    assert_eq!(
        activity_line("mcp__optchat__zoom", &json!({"rawInput": {"id": "918"}})),
        "Reading the chat history"
    );
}

#[test]
fn the_chiefs_control_calls_say_what_they_do_to_which_agent() {
    // Leo 2026-10-20: "Using optchat: control" sat over the typing dots for six minutes.
    let status = json!({"rawInput": {"action": "status", "id": "a31"}});
    assert_eq!(
        activity_line("mcp__optchat__control", &status),
        "Checking on a31"
    );
    let all = json!({"rawInput": {"action": "status"}});
    assert_eq!(
        activity_line("mcp__optchat__control", &all),
        "Checking on the agents"
    );
    let answer = json!({"rawInput": {"action": "answer", "id": "a7", "option": "allow"}});
    assert_eq!(
        activity_line("mcp__optchat__control", &answer),
        "Answering a7's prompt"
    );
    let interrupt = json!({"rawInput": {"action": "interrupt", "id": "a2", "message": "stop"}});
    assert_eq!(
        activity_line("mcp__optchat__control", &interrupt),
        "Steering a2"
    );
    // Input not streamed yet: still not the raw tool name.
    assert_eq!(
        activity_line("mcp__optchat__control", &json!({})),
        "Managing the agents"
    );
    assert_eq!(
        activity_line("mcp__optchat__peers", &json!({})),
        "Looking up the other machines"
    );
}

#[test]
fn other_mcp_tools_name_their_server_and_tool_in_words() {
    assert_eq!(
        activity_line("mcp__cmux__app_file_open", &json!({})),
        "Using cmux: app file open"
    );
    // A raw name in the title alone (no tool name) reads the same way.
    assert_eq!(
        activity_line("", &json!({"title": "mcp__cmux__workspace_list"})),
        "Using cmux: workspace list"
    );
}

#[test]
fn a_described_shell_call_shows_its_description() {
    let bash = json!({"kind": "execute", "title": "Run ls -la | head", "rawInput": {"command": "ls -la | head", "description": "List files"}});
    assert_eq!(activity_line("Bash", &bash), "List files");
    let bare = json!({"kind": "execute", "title": "git log -1"});
    assert_eq!(activity_line("Bash", &bare), "Running git log -1");
}

#[test]
fn a_calls_input_sharpens_its_line_but_keeps_its_start() {
    let mut run = RunSteps::default();
    run.tool_call(
        "t1",
        "mcp__optchat__tell",
        &json!({"title": "mcp__optchat__tell"}),
        None,
    );
    let first = run.take_live();
    let first = first
        .iter()
        .find(|f| f["type"] == "run.activity")
        .expect("an activity frame");
    assert_eq!(first["line"], "Telling an agent");
    std::thread::sleep(std::time::Duration::from_millis(5));
    run.tool_call(
        "t1",
        "mcp__optchat__tell",
        &json!({"rawInput": {"id": "a7"}}),
        None,
    );
    let second = run.take_live();
    let second = second
        .iter()
        .find(|f| f["type"] == "run.activity")
        .expect("an activity frame");
    assert_eq!(second["line"], "Telling a7");
    assert_eq!(
        second["since"], first["since"],
        "the same call keeps its start"
    );
    // A new call starts its own clock.
    std::thread::sleep(std::time::Duration::from_millis(5));
    run.tool_call("t2", "mcp__optchat__zoom", &json!({}), None);
    let third = run.take_live();
    let third = third
        .iter()
        .find(|f| f["type"] == "run.activity")
        .expect("an activity frame");
    assert_ne!(third["since"], first["since"]);
}
