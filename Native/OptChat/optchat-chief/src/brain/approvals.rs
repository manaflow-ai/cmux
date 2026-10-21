//! The Chief never asks a person before it acts (Lawrence, 2026-10-20). A
//! permission request of the running turn's session or of a child is
//! answered at once: allowed for the memory tools and the Chief's own
//! tools, refused for any other local effect. Requests reach the host only
//! from sessions that run with policy `ask`: a turn that carries another
//! person's text, and the children spawned under it (the spawn floor). Each
//! refusal goes to the trace.

use serde_json::{Value, json};

use super::Brain;
use crate::approval::{Answer, Pending, is_memory_tool, option_for, tool_name};

/// A turn that asks again for a request it was refused this many times is
/// stopped: the model is not left looping on a refused tool.
const REPEATS_BEFORE_STOP: u32 = 3;

/// The trace's approver of a refusal.
const REFUSED_BY: &str = "another person's turn";

impl Brain {
    /// Whether `session_id` is the running turn's session.
    pub(super) fn is_turn_session(&self, session_id: &str) -> bool {
        self.state
            .turn
            .as_ref()
            .and_then(|t| t.session_id.as_deref())
            == Some(session_id)
    }

    /// A permission request of the running turn's session.
    pub(super) fn turn_permission(
        &mut self,
        session_id: String,
        permission_id: String,
        request: Value,
    ) {
        let tool = tool_name(&request);
        if is_memory_tool(&request) || self.internal_allowed(&tool, &request) {
            // Reading the memory has no local effect; the Chief's own tools
            // are Chief talking to the person and its subagents.
            let option = option_for(&request, Answer::Allow);
            if let Err(e) =
                self.agents
                    .respond_permission(&session_id, &permission_id, option.as_deref())
            {
                // acpmux takes an allow only from the person's app. A
                // request left open holds the turn forever: refuse it, so
                // the model hears why and the turn goes on. The turn's
                // settings allow these tools, so this is a session started
                // before them.
                (self.log)(&format!("allowing {tool}: {e}; refusing it instead"));
                let deny = option_for(&request, Answer::Deny);
                if let Err(e) =
                    self.agents
                        .respond_permission(&session_id, &permission_id, deny.as_deref())
                {
                    (self.log)(&format!("refusing {tool}: {e}"));
                }
            }
            return;
        }
        if !self.turn_ask {
            (self.log)(&format!(
                "turn session asked for {tool} outside a turn another person started; left to its harness"
            ));
            return;
        }
        let pending = Pending {
            session_id,
            permission_id,
            tool,
            request,
            child: None,
        };
        let repeat = self
            .turn_denied
            .contains(&crate::approval::signature(&pending));
        self.refuse(&pending);
        if repeat && self.denial_stopped.is_none() {
            self.repeat_denials += 1;
            if self.repeat_denials >= REPEATS_BEFORE_STOP {
                // The model keeps asking for what was refused: end the turn.
                (self.log)(&format!(
                    "{} was refused and asked for again {} times: stopping the turn",
                    pending.tool, self.repeat_denials
                ));
                self.denial_stopped = Some(crate::approval::describe(
                    &pending.tool,
                    pending.request.pointer("/toolCall/rawInput"),
                ));
                self.interrupt.request_hard();
            }
        }
    }

    /// Whether one of the Chief's own tools runs without asking in this
    /// turn. Outside an ask turn, all of them. In an ask turn, only what
    /// stays in the conversation or under the ask floor:
    /// - `reply`, `react`, `stop`, `sleep`, and `spawn` (its children take
    ///   the ask floor);
    /// - `send` without attachments (an attachment uploads a local file);
    /// - `profile` reads (`history`, or no field), never a write or undo;
    /// - `control` `status`, `interrupt` with no message, and `answer` with
    ///   `deny`;
    /// - any other `tell` or `control` only to a subagent that asks for its
    ///   own effects (policy `ask`), so an untrusted turn cannot launder a
    ///   command through an approve-all subagent.
    pub(super) fn internal_allowed(&self, tool: &str, request: &Value) -> bool {
        self.internal_allowed_input(tool, request.pointer("/toolCall/rawInput"))
    }

    /// [`Self::internal_allowed`] on a call's `input` (its arguments).
    pub(super) fn internal_allowed_input(&self, tool: &str, input: Option<&Value>) -> bool {
        if !crate::approval::CHIEF_TOOLS.contains(&tool) {
            return false;
        }
        if !self.turn_ask {
            return true;
        }
        let get = |key: &str| input.and_then(|i| i.get(key));
        let field = |key: &str| get(key).and_then(Value::as_str);
        match tool {
            "mcp__optchat__send" => {
                return match get("attachments") {
                    None | Some(Value::Null) => true,
                    Some(Value::Array(a)) => a.is_empty(),
                    Some(_) => false,
                };
            }
            "mcp__optchat__profile" => {
                let Some(fields) = input.and_then(Value::as_object) else {
                    return input.is_none_or(Value::is_null);
                };
                return fields.iter().all(|(k, v)| k == "history" && v.is_boolean());
            }
            "mcp__optchat__control" => {
                let action = field("action").unwrap_or("status");
                let no_message = field("message").is_none_or(|m| m.trim().is_empty());
                let deny = field("option").is_none_or(|o| o.eq_ignore_ascii_case("deny"));
                if action == "status"
                    || (action == "interrupt" && no_message)
                    || (action == "answer" && deny && no_message)
                {
                    return true;
                }
            }
            "mcp__optchat__tell" => {}
            _ => return true,
        }
        let Some(id) = field("id") else {
            return false;
        };
        self.state
            .sub(id)
            .is_some_and(|(_, s)| s.policy.as_deref() == Some(crate::approval::ASK))
    }

    /// Whether the turn may run Chief tool `tool` (`mcp__optchat__<name>`)
    /// with `input` now. The turn's settings allow the Chief's tools with
    /// no permission request, so this is where a turn another person
    /// started is held to [`Self::internal_allowed`].
    pub fn turn_gate(&self, tool: &str, input: &Value) -> Result<(), String> {
        if !self.turn_ask || self.internal_allowed_input(tool, Some(input)) {
            return Ok(());
        }
        (self.log)(&format!("refused {tool} ({REFUSED_BY})"));
        Err(format!(
            "refused: this turn carries another person's text, so {tool} may not run with these arguments"
        ))
    }

    /// A permission request of a child that runs with policy `ask` (spawned
    /// under the spawn floor of a turn another person started): refused at
    /// once, never asked and never answered by the Chief itself.
    pub(super) fn child_permission(
        &mut self,
        child: &cmux_chief::acp::SessionSummary,
        permission_id: String,
        request: Value,
    ) {
        let pending = Pending {
            session_id: child.session_id.clone(),
            permission_id,
            tool: tool_name(&request),
            request,
            child: Some(child.name.clone()),
        };
        self.refuse(&pending);
    }

    /// Whether a child that runs with policy `ask` is still live: the spawn
    /// floor stays `ask` while one is (anything it spawns asks too).
    pub(super) fn ask_child_live(&self) -> bool {
        use cmux_chief::acp::SessionStatus;
        self.sessions.values().any(|s| {
            s.tags.get(crate::approval::POLICY_TAG).map(String::as_str)
                == Some(crate::approval::ASK)
                && !matches!(
                    s.status,
                    SessionStatus::Closed | SessionStatus::Disconnected
                )
        })
    }

    /// The policy floor for a child spawned now (`chief agents spawn` asks
    /// the host): `ask` during a turn another person started or while an
    /// `ask` child is live, so another person cannot reach the Mac through a
    /// subagent.
    pub fn spawn_policy(&self) -> Option<&'static str> {
        // The shared rule (cmux_chief::policy::spawn_floor).
        cmux_chief::policy::spawn_floor(
            false,
            self.turn_ask,
            self.ask_child_live(),
            self.ask_subagent_live(),
        )
    }

    /// Refuses `pending` (its reject option) and records the refusal in
    /// the trace.
    fn refuse(&mut self, pending: &Pending) {
        if pending.child.is_none() {
            let signature = crate::approval::signature(pending);
            if !self.turn_denied.contains(&signature) {
                self.turn_denied.push(signature);
            }
        }
        let option = option_for(&pending.request, Answer::Deny);
        let result = self.agents.respond_permission(
            &pending.session_id,
            &pending.permission_id,
            option.as_deref(),
        );
        (self.log)(&format!(
            "approval {}: refused {} ({REFUSED_BY}){}",
            pending.permission_id,
            pending.tool,
            match &result {
                Ok(()) => String::new(),
                Err(e) => format!(" (not delivered: {e})"),
            }
        ));
        if let Some(dir) = &self.settings.trace_dir {
            let fields = json!({
                "turn": self.state.turn.as_ref().map(|t| t.key.clone()),
                "session": pending.session_id,
                "permission": pending.permission_id,
                "tool": pending.tool,
                "child": pending.child,
                "decision": Answer::Deny.as_str(),
                "option": option,
                "approver": REFUSED_BY,
                "delivered": result.is_ok(),
            });
            if let Err(e) = crate::approval::record(dir, fields) {
                (self.log)(&format!("recording a refusal in the trace: {e}"));
            }
        }
    }
}
