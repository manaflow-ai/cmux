//! A smaller turn prefix (parity item 5): a turn session offers only the
//! Claude Code tools the Chief works with (Bash, Read, Edit, Write,
//! WebFetch, WebSearch, ToolSearch for its MCP servers); every other
//! built-in tool of Claude Code 2.1.287 is denied in the project settings,
//! which removes it from the tool list (measured 2026-10-08 through the
//! subrouter: the bare prefix fell from 20.7k to 12.1k tokens). Subagents do
//! the work and keep the full list, less the five a session must never use.

use std::collections::BTreeMap;

use optchat_chief::paths::Paths;
use optchat_chief::session_dir::{SessionSetup, write, write_subagent};
use serde_json::Value;

/// Claude Code 2.1.287's built-in tools (`system/init` `tools`), less the
/// ones a turn keeps.
const DROPPED: [&str; 22] = [
    "Task",
    "CronCreate",
    "CronDelete",
    "CronList",
    "DesignSync",
    "EnterWorktree",
    "ExitWorktree",
    "ListAgents",
    "Monitor",
    "NotebookEdit",
    "PushNotification",
    "ReportFindings",
    "ScheduleWakeup",
    "SendMessage",
    "Skill",
    "TaskCreate",
    "TaskGet",
    "TaskList",
    "TaskStop",
    "TaskUpdate",
    "Workflow",
    "Agent",
];

const KEPT: [&str; 7] = [
    "Bash",
    "Read",
    "Edit",
    "Write",
    "WebFetch",
    "WebSearch",
    "ToolSearch",
];

fn setup() -> SessionSetup {
    SessionSetup {
        exe: "/x/optchat-chief".into(),
        cmux_mcp: Some("/x/cmux".into()),
        env: BTreeMap::from([("MUX_HOME".into(), "/h".into())]),
        instructions: None,
        tools: optchat_chief::prompt::Tools::Mcp,
        user_env: Default::default(),
    }
}

fn denied(path: &std::path::Path) -> Vec<String> {
    let settings: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    settings["permissions"]["deny"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn a_turn_offers_only_the_chiefs_tools() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    paths.create().unwrap();
    write(&paths, &setup()).unwrap();
    let deny = denied(&paths.session.join(".claude").join("settings.json"));
    for tool in DROPPED
        .iter()
        .chain(&["AskUserQuestion", "EnterPlanMode", "ExitPlanMode"])
    {
        assert!(deny.iter().any(|d| d == tool), "{tool} denied: {deny:?}");
    }
    for tool in KEPT {
        assert!(!deny.iter().any(|d| d == tool), "{tool} kept: {deny:?}");
    }
}

#[test]
fn a_subagent_keeps_its_working_tools() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    paths.create().unwrap();
    write_subagent(&paths, &setup(), "task").unwrap();
    let deny = denied(&paths.subagent.join(".claude").join("settings.json"));
    assert_eq!(
        deny,
        vec![
            "Task",
            "Agent",
            "AskUserQuestion",
            "EnterPlanMode",
            "ExitPlanMode"
        ]
    );
}
