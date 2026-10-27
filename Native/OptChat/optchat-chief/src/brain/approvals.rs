//! The Chief never asks a person before it acts (Lawrence, 2026-10-20). A
//! permission request of the running turn's session or of a child is
//! answered at once: allowed for the memory tools and the Chief's own
//! tools, refused for any other local effect. Requests reach the host only
//! from sessions that run with policy `ask`: a turn that carries another
//! person's text, and the children spawned under it (the spawn floor). Each
//! refusal goes to the trace.
//!
//! No request waits on an answer nobody can give:
//! - acpmux takes an allow only from the person's app, and the app shows no
//!   button for a turn session (a turn session never gets a tab): a turn
//!   session's request the host does not allow is denied at once, in any
//!   turn.
//! - A request the host leaves open (a subagent's or child's prompt with no
//!   working approval button in the app, a deny acpmux did not take) is
//!   denied once it waits [`crate::approval::PERMISSION_WAIT`]
//!   (`deny_overdue_permissions_at`), with the reason in host.log and the
//!   trace.
//! - Every host-side deny of the turn's own request counts toward
//!   [`REPEATS_BEFORE_STOP`], so a model that calls a denied tool again and
//!   again is stopped.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::Brain;
use crate::approval::{Answer, Pending, is_memory_tool, option_for, tool_name};

/// A turn that asks again for a request it was refused this many times is
/// stopped: the model is not left looping on a refused tool.
const REPEATS_BEFORE_STOP: u32 = 3;

/// The trace's approver of a refusal.
const REFUSED_BY: &str = "another person's turn";

/// Why the host watches a request whose deny acpmux did not take.
pub(super) const NOT_DELIVERED: &str = "its deny was not delivered";

/// The trace's approver of a request nobody could answer.
const NO_ANSWER: &str = "no approver";

/// Why a turn was denied a request (the stop line's end).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum DenyWhy {
    /// A turn another person started may not run it.
    OtherPerson,
    /// It needs an approval nobody can give (only the person's app allows,
    /// and the app shows no button for it).
    NoApprover,
}

impl DenyWhy {
    /// The end of the turn's stop line: "I stopped: I kept trying to X, and ...".
    pub(super) fn reason(self) -> &'static str {
        match self {
            DenyWhy::OtherPerson => "a turn another person started may not do that",
            DenyWhy::NoApprover => "nobody can approve that here",
        }
    }
}

/// A permission request the host left open: denied once it waits longer
/// than [`crate::approval::PERMISSION_WAIT`].
#[derive(Clone, Debug)]
pub(super) struct Unanswered {
    pending: Pending,
    /// When the host first saw it (the brain's clock, ms since the epoch).
    since_ms: u64,
    /// Why nobody answers it, for host.log.
    why: &'static str,
}

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
            let Err(e) =
                self.agents
                    .respond_permission(&session_id, &permission_id, option.as_deref())
            else {
                return;
            };
            // acpmux takes an allow only from the person's app. A request
            // left open holds the turn forever: refuse it, so the model
            // hears why and the turn goes on. The turn's settings allow
            // these tools, so this is a session started before them.
            (self.log)(&format!("allowing {tool}: {e}; refusing it instead"));
            let pending = Pending {
                session_id,
                permission_id,
                tool,
                request,
                child: None,
            };
            self.refuse_as(&pending, DenyWhy::NoApprover, NO_ANSWER);
            return;
        }
        let pending = Pending {
            session_id,
            permission_id,
            tool,
            request,
            child: None,
        };
        if self.turn_ask {
            self.refuse_as(&pending, DenyWhy::OtherPerson, REFUSED_BY);
        } else {
            // The owner's turn under an asking policy, or a question the
            // policy never answers: the app shows no button for a turn
            // session, so nobody could answer it and the turn would wait
            // forever. The Chief never asks: refused at once.
            (self.log)(&format!(
                "the turn session asked for {}; nobody can answer a turn session's request: refusing it",
                pending.tool
            ));
            self.refuse_as(&pending, DenyWhy::NoApprover, NO_ANSWER);
        }
    }

    /// Refuses `pending`, a request of the running turn's session, as
    /// `approver` says, and counts the refusal: a turn that keeps asking for
    /// what it was refused stops ([`REPEATS_BEFORE_STOP`]).
    fn refuse_as(&mut self, pending: &Pending, why: DenyWhy, approver: &'static str) {
        self.refuse_by(pending, approver);
        self.count_denial(
            &pending.tool,
            pending.request.pointer("/toolCall/rawInput"),
            why,
        );
    }

    /// Counts one host-side deny of the running turn's call of `tool` with
    /// `input` (a refused request, a deny after a refused allow, a Chief
    /// tool the turn gate refused, an overdue request): its third repeat
    /// in the turn stops the turn, so the model is not left calling a
    /// denied tool again and again.
    pub(super) fn count_denial(&mut self, tool: &str, input: Option<&Value>, why: DenyWhy) {
        if self.state.turn.is_none() {
            return;
        }
        let signature = crate::approval::signature_of(tool, input);
        let repeat = self.turn_denied.contains(&signature);
        if !repeat {
            self.turn_denied.push(signature);
            return;
        }
        if self.denial_stopped.is_some() {
            return;
        }
        self.repeat_denials += 1;
        if self.repeat_denials >= REPEATS_BEFORE_STOP {
            // The model keeps asking for what was refused: end the turn.
            (self.log)(&format!(
                "{tool} was refused and asked for again {} times: stopping the turn",
                self.repeat_denials
            ));
            self.denial_stopped = Some((crate::approval::describe(tool, input), why));
            self.interrupt.request_hard();
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
        self.internal_allowed_input(tool, request.pointer("/toolCall/rawInput"), self.turn_ask)
    }

    /// [`Self::internal_allowed`] on a call's `input` (its arguments), in
    /// an ask turn when `ask`.
    pub(super) fn internal_allowed_input(
        &self,
        tool: &str,
        input: Option<&Value>,
        ask: bool,
    ) -> bool {
        if !crate::approval::CHIEF_TOOLS.contains(&tool) {
            return false;
        }
        if !ask {
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
            // Another person's words never become the owner's preference.
            "mcp__optchat__remember" => return false,
            // Nor a task that later runs as the Chief's own note: an ask
            // turn may only list the automations.
            "mcp__optchat__automation" => {
                return field("action").is_none_or(|a| a == "list");
            }
            // Nor spend the owner's money on a Cloud machine.
            "mcp__optchat__cloud_workspace" => return false,
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
    pub fn turn_gate(&mut self, tool: &str, input: &Value) -> Result<(), String> {
        let ask = self.turn_ask || (self.last_turn_ask && self.state.turn.is_none());
        if self.internal_allowed_input(tool, Some(input), ask) {
            return Ok(());
        }
        (self.log)(&format!("refused {tool} ({REFUSED_BY})"));
        // A model that calls it again and again is stopped, as for a
        // refused permission request.
        if self.turn_ask {
            self.count_denial(tool, Some(input), DenyWhy::OtherPerson);
        }
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
        self.refuse_by(pending, REFUSED_BY);
    }

    /// [`Self::refuse`] with `approver` in host.log and the trace. A refusal
    /// acpmux did not take is watched: the host denies it again once it is
    /// overdue (`deny_overdue_permissions_at`).
    pub(super) fn refuse_by(&mut self, pending: &Pending, approver: &'static str) {
        let option = option_for(&pending.request, Answer::Deny);
        let result = self.agents.respond_permission(
            &pending.session_id,
            &pending.permission_id,
            option.as_deref(),
        );
        (self.log)(&format!(
            "approval {}: refused {} ({approver}){}",
            pending.permission_id,
            pending.tool,
            match &result {
                Ok(()) => String::new(),
                Err(e) => format!(" (not delivered: {e})"),
            }
        ));
        if result.is_err() {
            self.watch_unanswered(pending.clone(), NOT_DELIVERED);
        } else {
            self.forget_unanswered(&pending.session_id, &pending.permission_id);
        }
        if let Some(dir) = &self.settings.trace_dir {
            let fields = json!({
                "turn": self.state.turn.as_ref().map(|t| t.key.clone()),
                "session": pending.session_id,
                "permission": pending.permission_id,
                "tool": pending.tool,
                "child": pending.child,
                "decision": Answer::Deny.as_str(),
                "option": option,
                "approver": approver,
                "delivered": result.is_ok(),
            });
            if let Err(e) = crate::approval::record(dir, fields) {
                (self.log)(&format!("recording a refusal in the trace: {e}"));
            }
        }
    }
    /// Watches `pending`, a request the host leaves open: once it waits
    /// [`crate::approval::PERMISSION_WAIT`] with no answer, it is denied.
    pub(super) fn watch_unanswered(&mut self, pending: Pending, why: &'static str) {
        if self.unanswered.iter().any(|u| {
            u.pending.session_id == pending.session_id
                && u.pending.permission_id == pending.permission_id
        }) {
            return;
        }
        let since_ms = (self.clock)();
        self.unanswered.push(Unanswered {
            pending,
            since_ms,
            why,
        });
    }

    /// `permission_id` of `session_id` was answered (or is gone).
    pub(super) fn forget_unanswered(&mut self, session_id: &str, permission_id: &str) {
        self.unanswered.retain(|u| {
            !(u.pending.session_id == session_id && u.pending.permission_id == permission_id)
        });
    }

    /// `session_id` has no pending request any more (its summary says 0).
    pub(super) fn forget_unanswered_of(&mut self, session_id: &str) {
        self.unanswered
            .retain(|u| u.pending.session_id != session_id);
    }

    /// The requests the host watches now: (session, permission), oldest
    /// first.
    pub fn unanswered_permissions(&self) -> Vec<(String, String)> {
        self.unanswered
            .iter()
            .map(|u| {
                (
                    u.pending.session_id.clone(),
                    u.pending.permission_id.clone(),
                )
            })
            .collect()
    }

    /// When the oldest watched request is due, on the run loop's clock.
    pub(super) fn next_unanswered_due(&self) -> Option<Instant> {
        let due = self.unanswered.iter().map(|u| u.since_ms).min()?
            + crate::approval::PERMISSION_WAIT.as_millis() as u64;
        let now = (self.clock)();
        Some(Instant::now() + Duration::from_millis(due.saturating_sub(now)))
    }

    /// Denies every watched request that waited
    /// [`crate::approval::PERMISSION_WAIT`] or longer by `now_ms` (the
    /// brain's clock): nobody answered it, and nobody may be able to. The
    /// reason goes to host.log and the trace; a deny of the running turn's
    /// own request counts toward stopping the turn.
    pub fn deny_overdue_permissions_at(&mut self, now_ms: u64) {
        let limit = crate::approval::PERMISSION_WAIT.as_millis() as u64;
        let (due, keep): (Vec<Unanswered>, Vec<Unanswered>) = std::mem::take(&mut self.unanswered)
            .into_iter()
            .partition(|u| now_ms.saturating_sub(u.since_ms) >= limit);
        self.unanswered = keep;
        for u in due {
            let p = &u.pending;
            // A subagent whose workspace opened after it asked: the person
            // sees the prompt with a working Allow button now.
            if u.why != NOT_DELIVERED
                && let Some(id) = self.state.sub_by_session(&p.session_id)
                && self
                    .state
                    .sub(&id)
                    .is_some_and(|(_, s)| Self::approval_shown(s))
            {
                continue;
            }
            let option = option_for(&p.request, Answer::Deny);
            let result =
                self.agents
                    .respond_permission(&p.session_id, &p.permission_id, option.as_deref());
            (self.log)(&format!(
                "permission {} of {} ({}{}) waited {} s with no answer ({}): denied{}",
                p.permission_id,
                p.session_id,
                p.tool,
                p.child
                    .as_deref()
                    .map(|c| format!(", {c}"))
                    .unwrap_or_default(),
                now_ms.saturating_sub(u.since_ms) / 1000,
                u.why,
                match &result {
                    Ok(()) => String::new(),
                    // Answered or gone meanwhile: nothing more to do.
                    Err(e) => format!(" (not delivered: {e})"),
                }
            ));
            if let Some(dir) = &self.settings.trace_dir {
                let fields = json!({
                    "turn": self.state.turn.as_ref().map(|t| t.key.clone()),
                    "session": p.session_id,
                    "permission": p.permission_id,
                    "tool": p.tool,
                    "child": p.child,
                    "decision": Answer::Deny.as_str(),
                    "option": option,
                    "approver": NO_ANSWER,
                    "reason": format!("no answer for {} s ({})", limit / 1000, u.why),
                    "delivered": result.is_ok(),
                });
                if let Err(e) = crate::approval::record(dir, fields) {
                    (self.log)(&format!("recording a refusal in the trace: {e}"));
                }
            }
            if let Some(id) = self.state.sub_by_session(&p.session_id)
                && let Some(sub) = self.state.sub_mut(&id)
                && sub
                    .permission
                    .as_ref()
                    .is_some_and(|q| q.id == p.permission_id)
            {
                sub.permission = None;
                self.save();
            }
            // A deny that was not delivered was counted when it was made.
            if p.child.is_none() && u.why != NOT_DELIVERED && self.is_turn_session(&p.session_id) {
                self.count_denial(
                    &p.tool,
                    p.request.pointer("/toolCall/rawInput"),
                    DenyWhy::NoApprover,
                );
            }
        }
    }
}
