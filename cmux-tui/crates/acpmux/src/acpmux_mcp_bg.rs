//! The `acpmux` MCP server's background-task tools (`hub/bg_tasks.rs`, docs/hibernation.md):
//! `bg_start`, `bg_list`, `bg_output` and `bg_stop`, each for this server's own chat. A task
//! started here runs under the daemon, not the harness, so it keeps running while the chat's
//! agent hibernates, and the woken agent finds it by id. `bg_start` sends this server's own
//! environment, which is the harness's, so the task sees what the agent's shell sees.

use super::{error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const TOOLS: [&str; 4] = ["bg_start", "bg_list", "bg_output", "bg_stop"];

pub(super) fn tools() -> Vec<Value> {
    let id =
        json!({"type": "string", "description": "The task's id, as bg_start or bg_list gave it."});
    vec![
        json!({"name": "bg_start", "description": "Run a shell command in the background: a dev server, a watcher, a long build or test run. It keeps running while this chat is idle or its agent hibernates, and after a restart; read it later with bg_output by its id. Prefer it to the harness's own background shell, which ends when the agent hibernates. Returns at once with the task's id.",
            "inputSchema": {"type": "object", "properties": {
                "command": {"type": "string", "description": "The command, run by /bin/sh -c."},
                "cwd": {"type": "string", "description": "Its folder (default: the chat's)."}},
                "required": ["command"]}}),
        json!({"name": "bg_list", "description": "This chat's background tasks, oldest first: id, state (running, exited, stopped, killed, lost), exit code and the tail of the output.",
            "inputSchema": {"type": "object", "properties": {}}}),
        json!({"name": "bg_output", "description": "Read a background task's output: by default its last 64 KiB; with fromByte, from there (pass the last nextByte to read only what is new). Each task keeps its newest 8 MiB of output; skippedBytes says how much before fromByte is gone.",
            "inputSchema": {"type": "object", "properties": {"id": id,
                "fromByte": {"type": "integer", "minimum": 0},
                "maxBytes": {"type": "integer", "minimum": 1, "maximum": 1048576}},
                "required": ["id"]}}),
        json!({"name": "bg_stop", "description": "Stop a background task: SIGTERM to its process group, SIGKILL 5 s later if it still runs.",
            "inputSchema": {"type": "object", "properties": {"id": id}, "required": ["id"]}}),
    ]
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, name: &str, args: &Value) -> Value {
    let mut params = args.clone();
    params["sessionId"] = json!(session);
    let m = match name {
        "bg_start" => {
            let env: serde_json::Map<String, Value> =
                std::env::vars().map(|(k, v)| (k, json!(v))).collect();
            params["env"] = Value::Object(env);
            method::MUX_BG_START
        }
        "bg_list" => method::MUX_BG_LIST,
        "bg_output" => method::MUX_BG_OUTPUT,
        "bg_stop" => method::MUX_BG_STOP,
        other => return error_result(format!("unknown tool: {other}")),
    };
    match daemon.request(m, params).await {
        // The agent reads the text; the exact bytes (`data`, base64) would only double it.
        Ok(mut r) => {
            if let Some(o) = r.as_object_mut() {
                o.remove("data");
            }
            ok(summary(name, &r), r)
        }
        Err(e) => refusal(e),
    }
}

/// One task as a line, then its tail.
fn task_line(t: &Value) -> String {
    let s = |k: &str| t[k].as_str().unwrap_or_default();
    let end = match (t["exitCode"].as_i64(), t["signal"].as_i64()) {
        (Some(code), _) => format!(" (exit {code})"),
        (_, Some(signal)) => format!(" (signal {signal})"),
        _ => String::new(),
    };
    format!("{}  [{}{end}]  {}\n{}", s("id"), s("state"), s("command"), s("tail").trim_end())
}

fn summary(name: &str, r: &Value) -> String {
    match name {
        "bg_list" => {
            let tasks = r["tasks"].as_array().cloned().unwrap_or_default();
            if tasks.is_empty() {
                return "No background tasks.".to_owned();
            }
            tasks.iter().map(task_line).collect::<Vec<_>>().join("\n\n")
        }
        "bg_output" => format!(
            "{}\n[{} bytes {}..{} of {}; next fromByte {}]",
            r["text"].as_str().unwrap_or_default(),
            r["id"].as_str().unwrap_or_default(),
            r["fromByte"],
            r["nextByte"],
            r["totalBytes"],
            r["nextByte"]
        ),
        _ => task_line(r),
    }
}
