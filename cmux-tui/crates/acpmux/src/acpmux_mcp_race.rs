//! The `acpmux` MCP server's race tools: `race_start` and `race_show`, the agent-callable form of
//! `acpmux race new` and `race show` (`cli/race.rs`). A race runs N attempts of a task as this
//! chat's sub-sessions, each in its own worktree, and an independent reviewer picks one
//! (`hub/races.rs`): best-of-N with a judge (RFD 0167 row 14). The requests are the CLI's, over
//! this server's connection, which carries the chat's caller token, so the race's parent is this
//! chat and the daemon refuses nothing here it would not refuse the CLI.

use super::{arg, error_result, ok, refusal};
use crate::cli::race::{MAX_ATTEMPTS, attempts, race_text, target};
use crate::client::Client;
use crate::rpc::method;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const TOOLS: &[&str] = &["race_start", "race_show"];

pub(super) fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "race_start",
            "description": "Best-of-N: run one task as several attempts, each a sub-session of this chat in its own git worktree of this chat's folder, then an independent reviewer reads every attempt and picks one. Give one model with attempts (4 attempts of codex) or several models. Returns the race id at once; race_show reads its state, each attempt's worktree and the reviewer's pick. Nothing is merged or discarded: losing worktrees are kept.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompt": {"type": "string", "description": "The task every attempt works on."},
                    "models": {"type": "array", "items": {"type": "string"}, "minItems": 1, "description": "HARNESS[/MODEL] per candidate, e.g. [\"codex\"] or [\"claude/opus\", \"codex/gpt-5.5\"]."},
                    "attempts": {"type": "integer", "minimum": 1, "maximum": MAX_ATTEMPTS, "description": "Attempts of each model (default 1; one model needs 2 or more)."},
                    "reviewer": {"type": "string", "description": "HARNESS[/MODEL] of the reviewer that picks the winner."},
                    "effort": {"type": "string", "description": "Thinking effort of the attempts (default: each harness's)."},
                    "reviewer_effort": {"type": "string", "description": "Thinking effort of the reviewer."}
                },
                "required": ["prompt", "models", "reviewer"]
            }
        }),
        json!({
            "name": "race_show",
            "description": "Read a race this chat started: its state (running, reviewing, completed, failed, cancelled), each attempt's state, worktree and summary, and the reviewer's pick and reason. Without race_id, lists this chat's races.",
            "inputSchema": {
                "type": "object",
                "properties": {"race_id": {"type": "string", "description": "The id race_start returned."}}
            }
        }),
    ]
}

/// The request for a call, or the refusal the agent reads.
pub(super) fn request(name: &str, args: &Value) -> Result<(&'static str, Value), String> {
    if name == "race_show" {
        return Ok(match arg(args, "race_id") {
            Some(id) => (method::MUX_RACE_GET, json!({"raceId": id})),
            None => (method::MUX_RACE_LIST, json!({})),
        });
    }
    let prompt = arg(args, "prompt").ok_or("prompt is required: the task")?;
    let reviewer = arg(args, "reviewer").ok_or("reviewer is required: HARNESS[/MODEL]")?;
    let models: Vec<String> = match args.get("models") {
        Some(Value::Array(items)) => items
            .iter()
            .map(|v| v.as_str().map(str::to_owned).ok_or("models must be strings"))
            .collect::<Result<_, _>>()?,
        Some(Value::String(one)) => vec![one.clone()],
        _ => return Err("models is required: HARNESS[/MODEL] per candidate".to_owned()),
    };
    let n = match args.get("attempts") {
        None | Some(Value::Null) => 1,
        Some(v) => v
            .as_u64()
            .filter(|n| (1..=u64::from(MAX_ATTEMPTS)).contains(n))
            .ok_or(format!("attempts must be 1 to {MAX_ATTEMPTS}"))? as u32,
    };
    if models.len() * (n as usize) < 2 {
        return Err(
            "a race needs at least two candidates: two models, or attempts of 2 or more".to_owned()
        );
    }
    let candidates = attempts(&models, n, arg(args, "effort")).map_err(|e| e.to_string())?;
    let mut params = json!({"prompt": prompt, "candidates": candidates});
    params.set(
        "reviewer",
        target(reviewer, arg(args, "reviewer_effort")).map_err(|e| e.to_string())?,
    );
    Ok((method::MUX_RACE_START, params))
}

pub(super) async fn call(daemon: &Arc<Client>, name: &str, args: &Value) -> Value {
    let (m, params) = match request(name, args) {
        Ok(r) => r,
        Err(e) => return error_result(e),
    };
    match daemon.request(m, params).await {
        Ok(reply) => {
            let text = match reply.get("races").and_then(Value::as_array) {
                Some(races) if races.is_empty() => "This chat has no races.".to_owned(),
                Some(races) => races.iter().map(race_text).collect::<Vec<_>>().join("\n"),
                None => race_text(&reply),
            };
            ok(text, reply)
        }
        Err(e) => refusal(e),
    }
}

#[cfg(test)]
#[path = "acpmux_mcp_race_tests.rs"]
mod tests;
