//! The `acpmux` MCP server's background-task tools (`hub/bg_tasks.rs`, docs/hibernation.md):
//! `bg_start`, `bg_list`, `bg_output` and `bg_stop`, each for this server's own chat. A task
//! started here runs under the daemon, not the harness, so it keeps running while the chat's
//! agent hibernates, and the woken agent finds it by id. The daemon gives the task the
//! environment the chat's agent runs with (`Hub::bg_env`), not this server's, which a harness
//! may filter (Codex passes only a few names).

use super::{error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const TOOLS: [&str; 4] = ["bg_start", "bg_list", "bg_output", "bg_stop"];

pub(super) fn tools() -> Vec<Value> {
    let id =
        json!({"type": "string", "description": "The task's id, as bg_start or bg_list gave it."});
    vec![
        json!({"name": "bg_start", "description": "Run a shell command in the background: a dev server, a watcher, a long build or test run. It keeps running while this chat is idle or its agent hibernates, and after a restart; read it later with bg_output by its id. Prefer it to the harness's own background shell, which ends when the agent hibernates. Returns at once with the task's id.",
            "inputSchema": {"type": "object", "properties": {
                "command": {"type": "string", "description": "The command, run by bash -c (/bin/sh where there is no bash), in the agent's environment."},
                "cwd": {"type": "string", "description": "Its folder (default: the chat's)."}},
                "required": ["command"]}}),
        json!({"name": "bg_list", "description": "This chat's background tasks, oldest first: id, state (running, exited, stopped, killed, lost), exit code and the tail of the output.",
            "inputSchema": {"type": "object", "properties": {}}}),
        json!({"name": "bg_output", "description": "Read a background task's output: by default its last 64 KiB; with fromByte, from there (pass the last nextByte to read only what is new). Each task keeps its newest 8 MiB of output; skippedBytes says how much before fromByte is gone.",
            "inputSchema": {"type": "object", "properties": {"id": id,
                "fromByte": {"type": "integer", "minimum": 0},
                "maxBytes": {"type": "integer", "minimum": 1, "maximum": 1048576}},
                "required": ["id"]}}),
        json!({"name": "bg_stop", "description": "Stop a background task: SIGTERM to its process group, then SIGKILL to the group 5 s later; returns once it ended.",
            "inputSchema": {"type": "object", "properties": {"id": id}, "required": ["id"]}}),
    ]
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, name: &str, args: &Value) -> Value {
    let mut params = match args {
        Value::Object(_) => args.clone(),
        Value::Null => json!({}),
        _ => return error_result("arguments must be an object".to_owned()),
    };
    params.set("sessionId", json!(session));
    let m = match name {
        "bg_start" => method::MUX_BG_START,
        "bg_list" => method::MUX_BG_LIST,
        "bg_output" => method::MUX_BG_OUTPUT,
        "bg_stop" => method::MUX_BG_STOP,
        other => return error_result(crate::mcp_hint::unknown_tool(other, TOOLS)),
    };
    match daemon.request(m, params).await {
        Ok(r) => ok(summary(name, &r), r),
        Err(e) => refusal(e),
    }
}

/// One task as a line, then its tail.
fn task_line(t: &Value) -> String {
    let s = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or_default();
    let int = |k: &str| t.get(k).and_then(Value::as_i64);
    let end = match (int("exitCode"), int("signal")) {
        (Some(code), _) => format!(" (exit {code})"),
        (_, Some(signal)) => format!(" (signal {signal})"),
        _ => String::new(),
    };
    format!("{}  [{}{end}]  {}\n{}", s("id"), s("state"), s("command"), s("tail").trim_end())
}

fn summary(name: &str, r: &Value) -> String {
    let field = |k: &str| r.get(k).unwrap_or(&Value::Null);
    match name {
        "bg_list" => {
            let tasks = field("tasks").as_array().map(Vec::as_slice).unwrap_or_default();
            if tasks.is_empty() {
                return "No background tasks.".to_owned();
            }
            tasks.iter().map(task_line).collect::<Vec<_>>().join("\n\n")
        }
        "bg_output" => format!(
            "{}\n[{} bytes {}..{} of {}; next fromByte {}]",
            field("text").as_str().unwrap_or_default(),
            field("id").as_str().unwrap_or_default(),
            field("fromByte"),
            field("nextByte"),
            field("totalBytes"),
            field("nextByte")
        ),
        _ => task_line(r),
    }
}
