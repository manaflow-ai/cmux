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
    // The call ends; a new call starts its own clock.
    run.tool_update(
        "t1",
        "mcp__optchat__tell",
        &json!({"status": "completed"}),
        "",
        None,
    );
    std::thread::sleep(std::time::Duration::from_millis(5));
    run.tool_call("t2", "mcp__optchat__zoom", &json!({}), None);
    let third = run.take_live();
    let third = third
        .iter()
        .find(|f| f["type"] == "run.activity")
        .expect("an activity frame");
    assert_ne!(third["since"], first["since"]);
}

fn activity(run: &mut RunSteps) -> Option<serde_json::Value> {
    run.take_live()
        .into_iter()
        .find(|f| f["type"] == "run.activity")
}

/// Claude Code runs a message's calls in order: a call announced while an
/// earlier one still runs waits for it. Leo's Chief showed "ToolSearch 3m 19s"
/// while a `gh pr view` loop announced just before it ran, and the
/// ToolSearch, announced second, waited behind it ("chief i tried has been
/// running toolsearch for >3min for some reason :(").
#[test]
fn the_line_names_the_call_that_runs_not_the_newest_announced() {
    let mut run = RunSteps::default();
    run.tool_call("bash", "Bash", &json!({"kind": "execute"}), None);
    let first = activity(&mut run).expect("an activity frame");
    assert_eq!(first["line"], "Running");
    std::thread::sleep(std::time::Duration::from_millis(5));
    run.tool_call(
        "search",
        "ToolSearch",
        &json!({"kind": "other", "title": "ToolSearch"}),
        None,
    );
    assert!(
        activity(&mut run).is_none(),
        "a call queued behind a running one does not take the line"
    );
    // The running call's input arrives: its line sharpens, its start stays.
    run.tool_call(
        "bash",
        "Bash",
        &json!({"kind": "execute", "rawInput": {"description": "Wait for the PR checks"}}),
        None,
    );
    let sharper = activity(&mut run).expect("an activity frame");
    assert_eq!(sharper["line"], "Wait for the PR checks");
    assert_eq!(sharper["since"], first["since"]);
    // It ends: the queued call runs now, and its clock starts now, not at its
    // announce (its wait behind the shell loop is not its own).
    std::thread::sleep(std::time::Duration::from_millis(5));
    let ended = optchat_chief::run::epoch_ms();
    run.tool_update("bash", "Bash", &json!({"status": "completed"}), "", None);
    let next = activity(&mut run).expect("an activity frame");
    assert_eq!(next["line"], "ToolSearch");
    assert!(next["since"].as_u64().unwrap() >= ended);
}

/// A call that ended no longer reads as running: with nothing else running
/// the turn waits on the model, so the line says so from the call's end.
#[test]
fn an_ended_call_gives_the_line_back_to_the_model() {
    let mut run = RunSteps::default();
    run.tool_call(
        "search",
        "ToolSearch",
        &json!({"kind": "other", "title": "ToolSearch"}),
        None,
    );
    let first = activity(&mut run).expect("an activity frame");
    assert_eq!(first["line"], "ToolSearch");
    std::thread::sleep(std::time::Duration::from_millis(5));
    run.tool_update(
        "search",
        "ToolSearch",
        &json!({"status": "completed"}),
        "",
        None,
    );
    let after = activity(&mut run).expect("an activity frame");
    assert_eq!(after["line"], "Thinking");
    assert!(after["since"].as_u64() > first["since"].as_u64());
}

/// Leo, 2026-10-20: "clear stale 'Telling' rows". A tell the turn was denied
/// gets no end of its own from the harness: the line kept naming it, and a
/// later call's end handed the line back to it ("Telling a31 · 4m").
#[test]
fn a_denied_tell_gives_the_line_back_and_never_returns() {
    use cmux_chief::acp::AcpmuxEvent;
    use optchat_chief::fold::TurnFold;
    let event = |seq: u64, dir: &str, kind: &str, msg: serde_json::Value| -> AcpmuxEvent {
        serde_json::from_value(json!({"seq": seq, "at": 1_792_400_000_000u64 + seq, "dir": dir, "kind": kind, "msg": msg}))
            .unwrap()
    };
    let update = |seq: u64, mut update: serde_json::Value| {
        let kind = update["sessionUpdate"].as_str().unwrap().to_owned();
        update["sessionUpdate"] = json!(kind);
        event(
            seq,
            "in",
            &kind,
            json!({"method": "session/update", "params": {"sessionId": "acp-1", "update": update}}),
        )
    };
    let mut fold = TurnFold::new();
    fold.apply(&update(1, json!({"sessionUpdate": "tool_call", "toolCallId": "tell-1", "title": "mcp__optchat__tell",
        "rawInput": {"id": "a31", "message": "hi"}, "_meta": {"claude": {"tool": "mcp__optchat__tell"}}})));
    fold.apply(&update(
        2,
        json!({"sessionUpdate": "tool_call", "toolCallId": "bash-1", "title": "Bash",
        "kind": "execute", "_meta": {"claude": {"tool": "Bash"}}}),
    ));
    let line = |fold: &mut TurnFold| {
        fold.take_run_live()
            .into_iter()
            .find(|f| f["type"] == "run.activity")
            .map(|f| f["line"].as_str().unwrap().to_owned())
    };
    assert_eq!(line(&mut fold).as_deref(), Some("Telling a31"));
    fold.apply(&event(3, "mux", "permission_request", json!({"permissionId": "perm1",
        "request": {"toolCall": {"toolCallId": "tell-1"}, "options": [
            {"optionId": "allow", "kind": "allow_once"}, {"optionId": "reject", "kind": "reject_once"}]}})));
    fold.apply(&event(
        4,
        "mux",
        "permission_decision",
        json!({"permissionId": "perm1",
        "outcome": {"outcome": "selected", "optionId": "reject"}}),
    ));
    assert_eq!(
        line(&mut fold).as_deref(),
        Some("Running"),
        "the denied tell's line went to the next call"
    );
    fold.apply(&update(
        5,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "bash-1", "status": "completed"}),
    ));
    assert_eq!(
        line(&mut fold).as_deref(),
        Some("Thinking"),
        "never back to the denied tell"
    );
    let steps = fold.take_run_steps(std::time::Instant::now(), true);
    let tell = steps
        .iter()
        .find(|s| s["id"].as_str().is_some_and(|i| i.contains("tell-1")))
        .unwrap();
    assert_eq!(tell["status"], "failed");
}

/// A call still running when the turn ends ends with it: no row keeps
/// reading as running after the turn.
#[test]
fn the_turns_end_ends_every_call_left_running() {
    let mut run = RunSteps::default();
    run.tool_call(
        "tell-1",
        "mcp__optchat__tell",
        &json!({"rawInput": {"id": "a31", "message": "hi"}}),
        None,
    );
    assert_eq!(activity(&mut run).unwrap()["line"], "Telling a31");
    let _ = run.take(std::time::Instant::now(), true);
    run.close_all();
    let steps = run.take(std::time::Instant::now(), true);
    let tell = steps
        .iter()
        .find(|s| s["kind"] == "tool")
        .expect("the tell's row is sent again");
    assert_eq!(tell["status"], "failed");
    assert_ne!(
        activity(&mut run).map(|f| f["line"].clone()),
        Some(json!("Telling a31"))
    );
}
