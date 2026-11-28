//! The `acpmux` MCP server's goal tools (`generic_goal.rs`, `hub/goal_tools.rs`): `goal_set`,
//! `goal_update` and `goal_get`, each for this server's own chat. The goal and its done-when are
//! kept on the chat by the daemon, not in the agent's context, so they survive a compaction; the
//! pane's goal strip draws the goal. On a harness with no goal of its own (Pi, OpenCode and the
//! rest), acpmux prompts the chat to go on at each completed turn until `goal_update` says
//! `complete` or `blocked`, a budget runs out, or 50 prompts went. Codex keeps its own `/goal`;
//! Claude Code continues through its `/loop`. Leo, 2026-11-05: "i meant can you do all of htem".

use super::{error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const TOOLS: [&str; 3] = ["goal_set", "goal_update", "goal_get"];
/// What every chat with the tools is told.
pub(super) const STEER: &str = "For work that runs until a condition holds, call goal_set with \
the objective and a checkable done-when; call goal_update with complete (evidence as the note) \
only once it holds, or blocked when you need the person.";

pub(super) fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "goal_set",
            "description": "Set this chat's goal: an objective and a done-when that can be checked (a command that passes, a PR that merged, a page that loads). Both survive compaction, and the person sees the goal above the composer. Without a harness goal, acpmux prompts you to keep going after every turn until goal_update complete or blocked, or a budget runs out. A new goal_set replaces the last and renames the chat. Refused in Codex: use its /goal.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "objective": {"type": "string", "description": "What to get done, in one sentence (\"Make the webviews test suite pass on feat-cmux-next\")."},
                    "doneWhen": {"type": "string", "description": "How anyone can check it is done, concretely (\"bun test in webviews exits 0\", \"PR 123 is merged\"). Not \"when it looks good\"."},
                    "tokenBudget": {"type": "integer", "minimum": 1, "description": "Optional: stop once the goal's turns spent this many tokens (counted where the harness reports usage)."},
                    "timeBudgetMinutes": {"type": "integer", "minimum": 1, "description": "Optional: stop once this many minutes passed since goal_set."}
                },
                "required": ["objective", "doneWhen"]
            }
        }),
        json!({
            "name": "goal_update",
            "description": "Report on this chat's goal. complete: done-when holds; say the evidence in note (\"bun test: 412 pass, 0 fail\"); acpmux stops prompting. blocked: you need the person (a decision, access, something only they can do); say what in note; acpmux stops prompting and the person sees it. running: going on again after blocked. running needs goal_set. Call complete only after checking done-when yourself.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "status": {"type": "string", "enum": ["running", "blocked", "complete"]},
                    "note": {"type": "string", "description": "One line: the evidence for complete, what you need for blocked, or where things stand."}
                },
                "required": ["status"]
            }
        }),
        json!({
            "name": "goal_get",
            "description": "Read this chat's goal: objective, doneWhen, status (lifecycle running, stalled, paused or done), budgets and what was spent, and how many continuation prompts went. Use it after a compaction to reread done-when. Null with no goal.",
            "inputSchema": {"type": "object", "properties": {}}
        }),
    ]
}

/// One goal tool call for chat `session`.
pub(super) async fn call(daemon: &Arc<Client>, session: &str, name: &str, args: &Value) -> Value {
    if session.is_empty() {
        return error_result("this server runs in no acpmux chat".to_owned());
    }
    let Some(object) = args.as_object() else {
        return error_result("arguments must be an object".to_owned());
    };
    let mut params = json!({"sessionId": session});
    if let Some(p) = params.as_object_mut() {
        for key in ["objective", "doneWhen", "tokenBudget", "timeBudgetMinutes", "status", "note"] {
            if let Some(v) = object.get(key) {
                p.insert(key.to_owned(), v.clone());
            }
        }
    }
    let m = match name {
        "goal_set" => method::MUX_GOAL_SET,
        "goal_update" => method::MUX_GOAL_UPDATE,
        _ => method::MUX_GOAL_GET,
    };
    match daemon.request(m, params).await {
        Ok(goal) => {
            let text = describe(name, &goal);
            ok(text, json!({"goal": goal}))
        }
        Err(e) => refusal(e),
    }
}

/// The result's one line.
pub(super) fn describe(name: &str, goal: &Value) -> String {
    if goal.is_null() {
        return "This chat has no goal.".to_owned();
    }
    let field = |k: &str| goal.get(k).and_then(Value::as_str).unwrap_or_default();
    let objective = field("objective");
    match (name, field("lifecycle")) {
        ("goal_set", _) => format!("Goal set: {objective}. Done when: {}.", field("doneWhen")),
        (_, "done") => format!("Goal complete: {objective}."),
        (_, "stalled") => format!("Goal stopped ({}): {objective}.", stop_reason(goal)),
        (_, lifecycle) => format!(
            "Goal {}: {objective}. Done when: {}.",
            if lifecycle.is_empty() { "running" } else { lifecycle },
            field("doneWhen")
        ),
    }
}

fn stop_reason(goal: &Value) -> &str {
    match goal.get("stopReason").and_then(Value::as_str) {
        Some("tokenBudget") => "token budget spent",
        Some("timeBudget") => "time budget spent",
        Some("continuationLimit") => "continuation limit",
        Some("blocked") => "blocked",
        _ => "stalled",
    }
}

#[cfg(test)]
#[path = "acpmux_mcp_goal_tests.rs"]
mod tests;
