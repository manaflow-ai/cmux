//! The `acpmux` MCP server's background-task tools (`hub/bg_tasks.rs`, docs/hibernation.md):
//! `bg_start`, `bg_list`, `bg_output` and `bg_stop`, each for this server's own chat. A task
//! started here runs under the daemon, not the harness, so it keeps running while the chat's
//! agent hibernates, and the woken agent finds it by id. The daemon gives the task the
//! environment the chat's agent runs with (`Hub::bg_env`), not this server's, which a harness
//! may filter (Codex passes only a few names).
//!
//! Condensed tools (Leo, 2026-11-03: "hmm claude code desktop's summarization of tool
//! calls/parsing of them seem kinda good? we should bea bel to do that AND have condensed tools
//! that are callable in acpmux/cmux-next..."): each takes an optional `description` (a few
//! words, what the call is for, which the transcript titles its row with), and each result's
//! first text line is a one-line outcome, also `structuredContent.summary`, with
//! `structuredContent.status` `running`, `ok` or `failed`. `bg_start` asks the daemon to tell
//! the chat when the task ends (`notify`, on unless false; `hub/bg_notify.rs`).

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
    let description = json!({"type": "string", "description": "A few words: what this call is for. The transcript titles the call with it."});
    vec![
        json!({"name": "bg_start", "description": "Run a shell command in the background: a dev server, a watcher, a long build or test run. It keeps running while this chat is idle or its agent hibernates, and after a restart; read it later with bg_output by its id. Prefer it to the harness's own background shell, which ends when the agent hibernates. Returns at once with the task's id. When it ends, this chat gets one message with how it ended and its last lines (unless notify is false), so there is no need to poll it.",
            "inputSchema": {"type": "object", "properties": {
                "command": {"type": "string", "description": "The command, run by bash -c (/bin/sh where there is no bash), in the agent's environment."},
                "cwd": {"type": "string", "description": "Its folder (default: the chat's)."},
                "description": {"type": "string", "description": "A few words: what the task is for. Kept with the task; bg_list, bg_output and the end message name it by this."},
                "notify": {"type": "boolean", "description": "Send this chat one message when the task ends (default true). It waits for a running turn to end; it never interrupts one."}},
                "required": ["command"]}}),
        json!({"name": "bg_list", "description": "This chat's background tasks, oldest first: id, state (running, exited, stopped, killed, lost), exit code and the tail of the output.",
            "inputSchema": {"type": "object", "properties": {"description": description}}}),
        json!({"name": "bg_output", "description": "Read a background task's output: by default its last 64 KiB; with fromByte, from there (pass the last nextByte to read only what is new). Each task keeps its newest 8 MiB of output; skippedBytes says how much before fromByte is gone.",
            "inputSchema": {"type": "object", "properties": {"id": id, "description": description,
                "fromByte": {"type": "integer", "minimum": 0},
                "maxBytes": {"type": "integer", "minimum": 1, "maximum": 1048576}},
                "required": ["id"]}}),
        json!({"name": "bg_stop", "description": "Stop a background task: SIGTERM to its process group, then SIGKILL to the group 5 s later; returns once it ended.",
            "inputSchema": {"type": "object", "properties": {"id": id, "description": description}, "required": ["id"]}}),
    ]
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, name: &str, args: &Value) -> Value {
    let mut params = match args {
        Value::Object(_) => args.clone(),
        Value::Null => json!({}),
        _ => return error_result("arguments must be an object".to_owned()),
    };
    params.set("sessionId", json!(session));
    // A call's own description titles its row; only a start keeps it, with the task.
    if name == "bg_start" {
        if params.get("notify").is_none_or(Value::is_null) {
            params.set("notify", json!(true));
        }
    } else if let Some(p) = params.as_object_mut() {
        p.remove("description");
    }
    let m = match name {
        "bg_start" => method::MUX_BG_START,
        "bg_list" => method::MUX_BG_LIST,
        "bg_output" => method::MUX_BG_OUTPUT,
        "bg_stop" => method::MUX_BG_STOP,
        other => return error_result(crate::mcp_hint::unknown_tool(other, TOOLS)),
    };
    match daemon.request(m, params).await {
        Ok(r) => {
            let (line, status) = outcome(name, &r);
            let mut structured = r;
            structured.set("summary", json!(line));
            structured.set("status", json!(status));
            ok(format!("{line}\n{}", summary(name, &structured)).trim_end().to_owned(), structured)
        }
        Err(e) => refusal(e),
    }
}

/// The result's one-line outcome and status (module docs): a task's own (`bg_run::outcome`, as
/// the daemon put it in its view), or for a list how many run, finished and failed.
fn outcome(name: &str, r: &Value) -> (String, &'static str) {
    if name != "bg_list" {
        return crate::bg_run::outcome(r);
    }
    let tasks = r.get("tasks").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    let count =
        |status: &str| tasks.iter().filter(|t| crate::bg_run::outcome(t).1 == status).count();
    let (running, ok, failed) = (count("running"), count("ok"), count("failed"));
    if tasks.is_empty() {
        return ("No background tasks.".to_owned(), "ok");
    }
    let plural = if tasks.len() == 1 { "" } else { "s" };
    let line = format!(
        "{} background task{plural}: {running} running, {ok} ok, {failed} failed",
        tasks.len()
    );
    let status = if running > 0 {
        "running"
    } else if failed > 0 {
        "failed"
    } else {
        "ok"
    };
    (line, status)
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
    let what = match s("description") {
        "" => s("command").to_owned(),
        d => format!("{d}: {}", s("command")),
    };
    format!("{}  [{}{end}]  {what}\n{}", s("id"), s("state"), s("tail").trim_end())
}

fn summary(name: &str, r: &Value) -> String {
    let field = |k: &str| r.get(k).unwrap_or(&Value::Null);
    match name {
        "bg_list" => {
            let tasks = field("tasks").as_array().map(Vec::as_slice).unwrap_or_default();
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A list's outcome counts its tasks by status; the list runs while any task runs.
    #[test]
    fn a_lists_outcome_counts_its_tasks() {
        let task =
            |state: &str, code: i64| json!({"state": state, "exitCode": code, "command": "c"});
        let r = json!({"tasks": [task("running", 0), task("exited", 0), task("exited", 1)]});
        let line = "3 background tasks: 1 running, 1 ok, 1 failed".to_owned();
        assert_eq!(outcome("bg_list", &r), (line, "running"));
        let done = json!({"tasks": [task("exited", 0), task("exited", 1)]});
        assert_eq!(outcome("bg_list", &done).1, "failed");
        assert_eq!(
            outcome("bg_list", &json!({"tasks": []})),
            ("No background tasks.".to_owned(), "ok")
        );
    }
}
