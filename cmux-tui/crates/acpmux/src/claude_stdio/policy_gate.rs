//! Claude Code's PreToolUse gate: the chat's acpmux permission policy held whatever Claude
//! Code's own mode (`hub/policy_gate.rs` has the why and the decision table).
//!
//! The gate is a hook callback ([`GATE_CALLBACK`]) registered at `initialize` for every tool
//! (`outbound::initialize_request`), which Claude Code fires before each tool call in every mode,
//! `auto` and `bypassPermissions` included, also for a subagent's calls. While the hub has
//! turned it on ([`super::POLICY_GATE`]: the chat's policy is narrower than approve-all), each
//! call that can act outside Claude Code is sent to the hub as [`super::TOOL_GATE`], shaped as a
//! `session/request_permission`, and the hub's decision becomes the hook's answer: `deny` blocks
//! the call with the reason, `ask` makes Claude Code ask (`can_use_tool`), `allow` runs it with
//! no prompt, and `none` lets Claude Code go on as it would. No answer the gate can read (an
//! error, an unknown decision) denies. Off, it answers at once with no decision.
//!
//! The matcher's `onFailure` is `block`: a hook callback answer Claude Code cannot use counts as
//! a block (Claude Code 2.1.319), so the gate fails closed there too.

use super::*;

/// The gate's hook callback id.
pub(super) const GATE_CALLBACK: &str = "acpmux-policy-gate";

/// How long Claude Code waits for the gate's answer, in seconds: the hub answers at once, but a
/// daemon that restarts adopts the agent's host first.
pub(super) const GATE_TIMEOUT_S: u64 = 600;

/// Claude Code's tools that act on nothing outside Claude Code itself (its plan, its task list,
/// its questions, its tool search, a background shell's output): never sent to the hub.
const OWN_TOOLS: [&str; 15] = [
    "TodoWrite",
    "TaskCreate",
    "TaskUpdate",
    "TaskList",
    "TaskGet",
    "TaskOutput",
    "BashOutput",
    "ToolSearch",
    "AskUserQuestion",
    "ExitPlanMode",
    "EnterPlanMode",
    "Skill",
    "SlashCommand",
    "ListMcpResourcesTool",
    "ReadMcpResourceTool",
];

/// The gate's state in one Claude Code process.
#[derive(Default)]
pub(super) struct PolicyGate {
    /// The policy the hub turned the gate on for, or `None`: off.
    policy: Mutex<Option<String>>,
    /// Claude Code's hook callback request ids that wait on the hub -> the ACP request id sent.
    asked: Mutex<HashMap<String, Value>>,
}

impl Translator {
    /// [`super::POLICY_GATE`]: turns the gate on for `params.policy`, or off for null.
    pub(super) async fn set_policy_gate(&self, params: &Value) -> Value {
        let policy = params.get("policy").and_then(Value::as_str).map(str::to_owned);
        let on = policy.is_some();
        *self.gate.policy.lock().await = policy;
        json!({"gate": on})
    }

    /// Claude Code fired the gate's hook for one tool call (`req`, its `hook_callback`): answered
    /// at once when the gate is off or the tool acts on nothing outside Claude Code, else the
    /// returned request asks the hub.
    pub(super) async fn gate_hook(&self, sid: &str, rid: &str, req: &Value) -> Option<Message> {
        let input = req.get("input").cloned().unwrap_or(Value::Null);
        let name = input.get("tool_name").and_then(Value::as_str).unwrap_or("");
        let policy = self.gate.policy.lock().await.clone();
        let Some(policy) = policy.filter(|_| !OWN_TOOLS.contains(&name)) else {
            self.stdin_replies.lock().await.push(hook_reply(rid, json!({})));
            return None;
        };
        let tool_input = input.get("tool_input").cloned().unwrap_or(Value::Null);
        let use_id = input.get("tool_use_id").or_else(|| req.get("tool_use_id")).cloned();
        let mut call = json!({
            "toolCallId": use_id,
            "title": tool_title(name, &tool_input),
            "kind": tool_kind(name),
            "status": "pending",
            "rawInput": tool_input,
            "_meta": {"claude": {"tool": name, "gate": "preToolUse", "agentId": input.get("agent_id")}}
        });
        with_edit(&mut call, name, &tool_input);
        let n = self.next_control.fetch_add(1, Ordering::SeqCst);
        let acp_id = Value::from(1_000_000_i64.saturating_add(n));
        self.gate.asked.lock().await.insert(rid.to_owned(), acp_id.clone());
        Some(Message::request(
            acp_id,
            TOOL_GATE,
            json!({
                "sessionId": sid,
                "policy": policy,
                "toolCall": call,
                "options": [
                    {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}
                ],
            }),
        ))
    }

    /// The hub's answer `id` to a gate request, as the hook's answer to Claude Code; `None` when
    /// `id` is not one.
    pub(super) async fn gate_answer(
        &self,
        id: &Value,
        result: Option<&Value>,
        error: bool,
    ) -> Option<Value> {
        let rid = {
            let mut asked = self.gate.asked.lock().await;
            let rid = asked.iter().find(|(_, v)| *v == id).map(|(k, _)| k.clone())?;
            asked.remove(&rid);
            rid
        };
        let decision = result.and_then(|r| r.get("decision")).and_then(Value::as_str);
        let reason = result.and_then(|r| r.get("reason")).and_then(Value::as_str);
        let output = match (error, decision) {
            (false, Some("none")) => json!({}),
            (false, Some(d @ ("allow" | "ask"))) => pre_tool(d, reason.unwrap_or("acpmux policy")),
            (false, Some("deny")) => {
                pre_tool("deny", reason.unwrap_or("acpmux denied this tool call"))
            }
            _ => pre_tool(
                "deny",
                "acpmux could not check this tool call against the chat's permission policy",
            ),
        };
        Some(hook_reply(&rid, output))
    }

    /// Claude Code no longer waits on gate hook `rid`: whether it was one.
    pub(super) async fn forget_gate(&self, rid: &str) -> bool {
        self.gate.asked.lock().await.remove(rid).is_some()
    }
}

/// A PreToolUse hook output with `decision` and `reason`.
fn pre_tool(decision: &str, reason: &str) -> Value {
    json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }})
}

/// The `control_response` that answers hook callback `rid` with `output`.
pub(super) fn hook_reply(rid: &str, output: Value) -> Value {
    json!({"type": "control_response", "response": {
        "subtype": "success", "request_id": rid, "response": output}})
}
