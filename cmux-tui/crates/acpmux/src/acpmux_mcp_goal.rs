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
pub(super) const STEER: &str = "For work that should run until a condition holds (make the \
suite pass, land the PR, finish the migration), call goal_set with the objective and a checkable \
done-when; the chat keeps them across compaction. Call goal_update with status complete, with \
the evidence as the note, only once done-when holds, and with blocked when you need the person.";

pub(super) fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "goal_set",
            "description": "Set this chat's goal: an objective and a done-when that can be checked (a command that passes, a PR that merged, a page that loads). The chat keeps both outside your context, so they survive compaction, and the person sees the goal above the composer. On harnesses without a goal of their own, acpmux prompts you to keep going after every turn until you call goal_update with complete or blocked, or a budget runs out. A new goal_set replaces the last. Refused in a Codex chat: use Codex's own /goal there.",
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
            "description": "Report on this chat's goal. complete: done-when holds; say the evidence in note (\"bun test: 412 pass, 0 fail\"); acpmux stops prompting. blocked: you need the person (a decision, access, something only they can do); say what in note; acpmux stops prompting and the person sees it. running: going on again after blocked. Call complete only after checking done-when yourself, never on a guess.",
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
            "description": "Read this chat's goal: objective, doneWhen, status (lifecycle running, stalled, paused or done), budgets and what was spent, and how many continuation prompts went. Use it after a compaction or when a continuation prompt arrives and you need the done-when again. Null when the chat has no goal.",
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
mod tests {
    use super::*;

    #[test]
    fn each_tool_says_what_to_pass_and_the_result_reads_in_one_line() {
        let tools = tools();
        let names: Vec<&str> = tools.iter().filter_map(|t| t.get("name")?.as_str()).collect();
        assert_eq!(names, TOOLS);
        let set = tools.first().and_then(|t| t.pointer("/inputSchema/required"));
        assert_eq!(set, Some(&json!(["objective", "doneWhen"])));

        let goal = json!({"objective": "Ship it", "doneWhen": "CI green", "lifecycle": "running"});
        assert_eq!(describe("goal_set", &goal), "Goal set: Ship it. Done when: CI green.");
        assert_eq!(describe("goal_get", &goal), "Goal running: Ship it. Done when: CI green.");
        let done = json!({"objective": "Ship it", "lifecycle": "done"});
        assert_eq!(describe("goal_update", &done), "Goal complete: Ship it.");
        let spent =
            json!({"objective": "Ship it", "lifecycle": "stalled", "stopReason": "timeBudget"});
        assert_eq!(describe("goal_get", &spent), "Goal stopped (time budget spent): Ship it.");
        assert_eq!(describe("goal_get", &Value::Null), "This chat has no goal.");
    }
}
