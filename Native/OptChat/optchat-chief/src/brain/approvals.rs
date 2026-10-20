//! A remote-origin turn's approvals (README "Remote-origin messages"): the
//! turn session's permission requests, answered at once for the memory
//! tools and otherwise asked in the Chief chat; each answer is recorded in
//! the trace with the approving device.

use cmux_conversation::{Message, Origin};
use serde_json::{Value, json};

use super::{Brain, reply_entry};
use crate::approval::{Answer, Pending, is_memory_tool, option_for, question, tool_name};

/// A turn that asks again for a request it was denied this many times is
/// stopped: the model is not left looping on a refused tool.
const REPEATS_BEFORE_STOP: u32 = 3;

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
                (self.log)(&format!("allowing {tool}: {e}"));
            }
            return;
        }
        if !self.turn_ask {
            (self.log)(&format!(
                "turn session asked for {tool} outside an ask turn; left to its harness"
            ));
            return;
        }
        let pending = Pending {
            session_id,
            permission_id,
            tool,
            request,
            child: None,
            conversation: self.turn_side(),
            why: self.turn_why.clone(),
        };
        // Stop means stop: a stopped turn asks nobody, it is denied at once.
        if self.owner_stopped {
            self.respond(&pending, Answer::Deny, "the owner stopped the turn", None);
            return;
        }
        if self.denial_stopped.is_some() {
            self.respond(&pending, Answer::Deny, "the turn was stopped", None);
            return;
        }
        // A request denied once in this turn is not asked again.
        if self
            .turn_denied
            .contains(&crate::approval::signature(&pending))
        {
            self.respond(&pending, Answer::Deny, "denied earlier in this turn", None);
            self.repeat_denials += 1;
            if self.repeat_denials >= REPEATS_BEFORE_STOP {
                // The model keeps asking for what was refused: end the turn.
                (self.log)(&format!(
                    "{} was denied and asked for again {} times: stopping the turn",
                    pending.tool, self.repeat_denials
                ));
                self.denial_stopped = Some(crate::approval::describe(
                    &pending.tool,
                    pending.request.pointer("/toolCall/rawInput"),
                ));
                self.interrupt.request_hard();
            }
            return;
        }
        let key = format!(
            "approval:{}:{}",
            self.state.turn.as_ref().map_or("", |t| t.key.as_str()),
            pending.permission_id
        );
        self.ask_person(pending, &key);
    }

    /// The name of the paired device that sent one of `items` (its
    /// participant's display name), else "another device".
    pub(super) fn device_name(&self, items: &[super::Queued]) -> String {
        let install = items.iter().find_map(|i| match &i.source {
            super::Source::Message {
                remote: Some(install),
                ..
            } => Some(install.clone()),
            _ => None,
        });
        install
            .and_then(|install| {
                let id = format!("remote_{install}");
                self.summary.as_ref().and_then(|s| {
                    s.participants
                        .iter()
                        .find(|p| p.id == id)
                        .map(|p| p.display_name.clone())
                })
            })
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| "another device".to_owned())
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
        if !crate::approval::CHIEF_TOOLS.contains(&tool) {
            return false;
        }
        if !self.turn_ask {
            return true;
        }
        let input = request.pointer("/toolCall/rawInput");
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

    /// A permission request of a child that runs with policy `ask` (spawned
    /// under the ask floor): asked in the Chief chat with the child's name,
    /// never answered by the Chief itself.
    pub(super) fn child_permission(
        &mut self,
        child: &cmux_chief::acp::SessionSummary,
        permission_id: String,
        request: Value,
    ) {
        let key = format!("approval:{}:{}", child.session_id, permission_id);
        let pending = Pending {
            session_id: child.session_id.clone(),
            permission_id,
            tool: tool_name(&request),
            request,
            child: Some(child.name.clone()),
            conversation: None,
            why: None,
        };
        self.ask_person(pending, &key);
    }

    /// Asks in the conversation the request belongs to (G9): the running
    /// turn's, or the main one for a child.
    fn ask_person(&mut self, pending: Pending, key: &str) {
        let conversation = pending
            .conversation
            .clone()
            .or_else(|| self.state.conversation.clone());
        if let Some(conversation) = conversation {
            // The card (a question part with Allow once and Deny); a client
            // without cards shows its prompt and options, and an owner that
            // refuses the part gets the two-line text instead.
            let mut entry = reply_entry(conversation, key, "");
            if let cmux_conversation::Op::MessageSend { parts, .. } = &mut entry.op {
                *parts = vec![crate::approval::card(&pending)];
            }
            entry.plain_text = Some(question(&pending));
            self.approvals.push_back(pending);
            self.state.outbox.push(entry);
            self.save();
            self.flush_outbox();
        } else {
            self.approvals.push_back(pending);
        }
    }

    /// A card was answered (`question.answer` on the Chief's own message):
    /// the owner's selection answers the approval it names, once.
    pub(super) fn answer_card(&mut self, conversation: &str, message: &Message) {
        for part in &message.parts {
            let cmux_conversation::Part::Question(q) = part else {
                continue;
            };
            let cmux_conversation::QuestionState::Answered { answer } = &q.state else {
                continue;
            };
            let Some(permission) = q.permission.as_deref() else {
                continue;
            };
            let Some(respondent) = answer.respondent.as_ref() else {
                continue;
            };
            // The card answers only the approval it was posted for, in the
            // conversation it was posted in.
            let main = self.state.conversation.clone();
            let Some(k) = self.approvals.iter().position(|p| {
                p.permission_id == permission
                    && p.session_id == q.session
                    && p.conversation
                        .as_ref()
                        .or(main.as_ref())
                        .map(String::as_str)
                        == Some(conversation)
            }) else {
                continue;
            };
            // Only the owner approves (a paired device answers as its
            // person). Another participant's answer closed this card, so
            // the owner gets a fresh one; the request stays pending.
            if respondent.participant != self.settings.membership.owner {
                (self.log)(&format!(
                    "approval {permission}: answered by {}, not the owner; asking the owner again",
                    respondent.participant
                ));
                if let Some(pending) = self.approvals.remove(k) {
                    let key = format!("approval:again:{}:{}", message.id, pending.permission_id);
                    self.ask_person(pending, &key);
                }
                continue;
            }
            let Some(decision) = crate::approval::card_answer(answer) else {
                continue;
            };
            let Some(pending) = self.approvals.remove(k) else {
                continue;
            };
            let approver = format!(
                "{} ({})",
                respondent
                    .device
                    .as_deref()
                    .unwrap_or(respondent.display_name.as_str()),
                respondent.participant
            );
            let install = respondent
                .remote
                .then(|| respondent.device.clone())
                .flatten();
            self.respond(&pending, decision, &approver, install.as_deref());
        }
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
    /// the host): `ask` during an ask turn or while an ask child is live,
    /// unless the Mac turned on remote.autoApprove.
    pub fn spawn_policy(&self) -> Option<&'static str> {
        // The shared rule (cmux_chief::policy::spawn_floor).
        cmux_chief::policy::spawn_floor(
            self.chief.remote_auto_approve,
            self.turn_ask,
            self.ask_child_live(),
            self.ask_subagent_live(),
        )
    }

    /// Drops the running turn's own pending approvals (its session ends);
    /// children's stay.
    pub(super) fn clear_turn_approvals(&mut self) {
        self.approvals.retain(|p| p.child.is_some());
    }

    /// Whether an approval waits for an answer in `conversation` (None:
    /// the main one).
    pub(super) fn has_approval(&self, conversation: Option<&str>) -> bool {
        self.approvals
            .iter()
            .any(|p| p.conversation.as_deref() == conversation)
    }

    /// A person in `conversation` (None: main) answered that conversation's
    /// oldest pending approval with `message`; another conversation's
    /// approvals are never answered from here.
    pub(super) fn answer_approval(
        &mut self,
        answer: Answer,
        message: &Message,
        conversation: Option<&str>,
    ) {
        let Some(k) = self
            .approvals
            .iter()
            .position(|p| p.conversation.as_deref() == conversation)
        else {
            return;
        };
        let Some(pending) = self.approvals.remove(k) else {
            return;
        };
        let install = message
            .origin
            .as_ref()
            .map(|Origin::Remote { install }| install.clone());
        self.respond(&pending, answer, &message.author, install.as_deref());
    }

    /// Denies the running turn's pending approvals (`why` is the trace's
    /// approver); children's stay for a person.
    pub(super) fn deny_pending(&mut self, why: &str) {
        let (turn, children): (Vec<Pending>, Vec<Pending>) =
            self.approvals.drain(..).partition(|p| p.child.is_none());
        self.approvals.extend(children);
        for pending in turn {
            self.respond(&pending, Answer::Deny, why, None);
        }
    }

    fn respond(
        &mut self,
        pending: &Pending,
        answer: Answer,
        approver: &str,
        install: Option<&str>,
    ) {
        if answer == Answer::Deny && pending.child.is_none() {
            let signature = crate::approval::signature(pending);
            if !self.turn_denied.contains(&signature) {
                self.turn_denied.push(signature);
            }
        }
        let option = option_for(&pending.request, answer);
        let result = self.agents.respond_permission(
            &pending.session_id,
            &pending.permission_id,
            option.as_deref(),
        );
        (self.log)(&format!(
            "approval {}: {} {} by {approver}{}",
            pending.permission_id,
            answer.as_str(),
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
                "decision": answer.as_str(),
                "option": option,
                "approver": approver,
                "install": install,
                "delivered": result.is_ok(),
            });
            if let Err(e) = crate::approval::record(dir, fields) {
                (self.log)(&format!("recording an approval in the trace: {e}"));
            }
        }
    }
}
