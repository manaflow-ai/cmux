//! A remote-origin turn's approvals (README "Remote-origin messages"): the
//! turn session's permission requests, answered at once for the memory
//! tools and otherwise asked in the Chief chat as a card (Allow / Deny);
//! each answer is recorded in the trace with the approving device.

use cmux_conversation::{Message, Op, Origin, Part, Question, QuestionState};
use serde_json::{Value, json};

use super::{Brain, op_entry, reply_entry};
use crate::approval::{Answer, Pending, card, card_answer, is_memory_tool, option_for, tool_name};

/// An approval card the Chief posted, kept until its approval is settled
/// so a card left pending can be cancelled.
pub(super) struct Card {
    pub permission_id: String,
    /// The `message.send` key, matched when the owner confirms the send.
    pub key: String,
    pub conversation: String,
    pub question: Question,
    pub message_id: Option<String>,
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
        if is_memory_tool(&request) {
            // Reading the memory has no local effect.
            let option = option_for(&request, Answer::Allow);
            if let Err(e) =
                self.agents
                    .respond_permission(&session_id, &permission_id, option.as_deref())
            {
                // acpmux takes an allow only from the person, and the
                // harness may not pre-allow MCP tools: a refused allow would
                // leave the turn waiting on a request nobody is asked. A
                // deny lets the turn go on without the memory read.
                (self.log)(&format!(
                    "memory tool {tool}: acpmux refused the Chief's allow ({e}); denied so the turn goes on"
                ));
                let deny = option_for(&request, Answer::Deny);
                if let Err(e) =
                    self.agents
                        .respond_permission(&session_id, &permission_id, deny.as_deref())
                {
                    (self.log)(&format!("denying {tool}: {e}"));
                }
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
        };
        let key = format!(
            "approval:{}:{}",
            self.state.turn.as_ref().map_or("", |t| t.key.as_str()),
            pending.permission_id
        );
        self.ask_person(pending, &key);
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
        };
        self.ask_person(pending, &key);
    }

    /// Asks in the conversation the request belongs to (G9): the running
    /// turn's, or the main one for a child.
    fn ask_person(&mut self, pending: Pending, key: &str) {
        self.post_card(&pending, key);
        self.approvals.push_back(pending);
    }

    /// Posts `pending`'s card under `key` (a fresh key for a card posted
    /// again: the owner keeps every key it saw) and remembers it.
    fn post_card(&mut self, pending: &Pending, key: &str) {
        let question = card(pending, self.turn_ask_reason);
        let Some(conversation) = pending
            .conversation
            .clone()
            .or_else(|| self.state.conversation.clone())
        else {
            return;
        };
        let mut entry = reply_entry(conversation.clone(), key, "");
        if let Op::MessageSend { parts, .. } = &mut entry.op {
            *parts = vec![Part::Question(question.clone())];
        }
        // An owner that refuses the card gets the question as text.
        entry.plain_text = Some(crate::approval::question_text(&question.items[0].prompt));
        self.approval_cards.push(Card {
            permission_id: pending.permission_id.clone(),
            key: key.to_owned(),
            conversation,
            question,
            message_id: None,
        });
        self.state.outbox.push(entry);
        self.save();
        self.flush_outbox();
    }

    /// Posts `text` in `pending`'s conversation under `key`.
    fn say_about(&mut self, pending: &Pending, key: &str, text: &str) {
        let Some(conversation) = pending
            .conversation
            .clone()
            .or_else(|| self.state.conversation.clone())
        else {
            return;
        };
        self.state.outbox.push(reply_entry(conversation, key, text));
        self.save();
        self.flush_outbox();
    }

    /// The owner confirmed the send of `key`: an approval card's message id.
    pub(super) fn card_sent(&mut self, key: &str, message_id: &str) {
        if let Some(card) = self.approval_cards.iter_mut().find(|c| c.key == key) {
            card.message_id = Some(message_id.to_owned());
        }
    }

    /// The approval of `permission_id` was settled some other way than its
    /// card (a chat reply, a newer message, the turn's end): the card moves
    /// from pending to cancelled so nobody answers it. Best effort.
    fn cancel_card(&mut self, permission_id: &str) {
        let Some(k) = self
            .approval_cards
            .iter()
            .position(|c| c.permission_id == permission_id)
        else {
            return;
        };
        let card = self.approval_cards.remove(k);
        let Some(message_id) = card.message_id else {
            (self.log)(&format!(
                "approval {permission_id}: its card was never confirmed; it stays as sent"
            ));
            return;
        };
        let question = Question {
            state: QuestionState::Cancelled,
            ..card.question
        };
        self.state.outbox.push(op_entry(
            card.conversation,
            &format!("{}:cancel", card.key),
            Op::MessageEdit {
                message_id,
                parts: vec![Part::Question(question)],
            },
        ));
        self.save();
        self.flush_outbox();
    }

    /// Forgets the card of an approval its card answered (it is closed).
    fn forget_card(&mut self, permission_id: &str) {
        self.approval_cards
            .retain(|c| c.permission_id != permission_id);
    }

    /// An updated message of the Chief's own: when it is an approval card
    /// the owner answered, the answer settles its pending approval. The Mac
    /// app answers acpmux itself (with the person's proof) before it answers
    /// the card, so for an allow acpmux no longer holds the request; the
    /// Chief's own answer then only confirms that. A card answered by anyone
    /// but the owner, or an answer acpmux refuses, leaves the approval
    /// waiting with a fresh card. Side conversations' cards are answered the
    /// same way once their updates reach the brain (they do not yet).
    pub(super) fn on_card_update(&mut self, message: &Message) {
        for part in &message.parts {
            let Part::Question(question) = part else {
                continue;
            };
            let Some((permission, answer, who)) = card_answer(question) else {
                continue;
            };
            let Some(k) = self
                .approvals
                .iter()
                .position(|p| p.permission_id == permission)
            else {
                continue;
            };
            // That card is answered: nothing is left to click on it.
            self.forget_card(&permission);
            let fresh = format!("approval:{permission}:card:{}", message.seq);
            if who != self.settings.membership.owner {
                // The same rule as a chat answer: only the owner approves
                // effects on this Mac.
                (self.log)(&format!(
                    "approval {permission}: the card's {} by {who} is not the owner's; asked again",
                    answer.as_str()
                ));
                let Some(pending) = self.approvals.get(k).cloned() else {
                    continue;
                };
                self.say_about(
                    &pending,
                    &format!("{fresh}:note"),
                    &format!(
                        "Only the owner of this Mac can answer that approval, so {} is still waiting.",
                        pending.tool
                    ),
                );
                self.post_card(&pending, &fresh);
                continue;
            }
            let Some(pending) = self.approvals.remove(k) else {
                continue;
            };
            let option = option_for(&pending.request, answer);
            match self.answer_acpmux(&pending, answer, &who) {
                Ok(()) => {
                    self.trace_approval(&pending, answer, option, &who, None, true);
                }
                Err(e) if settled(&e) => {
                    (self.log)(&format!(
                        "approval {permission}: {} in the app by {who}",
                        answer.as_str()
                    ));
                    self.trace_approval(&pending, answer, option, &who, None, true);
                }
                Err(e) => {
                    // An answer without the person's proof (an allow from a
                    // paired device): acpmux still waits, so the approval
                    // stays, with a fresh card to answer in the app.
                    self.trace_approval(&pending, answer, option, &who, None, false);
                    let text = format!(
                        "That {} was not accepted, so {} is still waiting: {e}. Allow it on the new card in the cmux app on this Mac, or reply deny or send a new message to skip it.",
                        answer.as_str(),
                        pending.tool
                    );
                    self.say_about(&pending, &format!("{fresh}:note"), &text);
                    self.post_card(&pending, &fresh);
                    self.approvals.insert(k, pending);
                }
            }
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
        let (turn, children): (Vec<Pending>, Vec<Pending>) =
            self.approvals.drain(..).partition(|p| p.child.is_none());
        self.approvals.extend(children);
        for pending in turn {
            self.cancel_card(&pending.permission_id);
        }
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
    /// approvals are never answered from here. A pending approval acpmux no
    /// longer holds (answered in its agent pane, or on a card the brain did
    /// not see) is dropped as settled, and the answer goes to the next one.
    pub(super) fn answer_approval(
        &mut self,
        answer: Answer,
        message: &Message,
        conversation: Option<&str>,
    ) {
        let install = message
            .origin
            .as_ref()
            .map(|Origin::Remote { install }| install.clone());
        loop {
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
            match self.respond(&pending, answer, &message.author, install.as_deref()) {
                Ok(()) => {
                    self.cancel_card(&pending.permission_id);
                    return;
                }
                Err(e) if settled(&e) => {
                    (self.log)(&format!(
                        "approval {}: acpmux no longer holds it; dropped as settled",
                        pending.permission_id
                    ));
                    self.cancel_card(&pending.permission_id);
                }
                Err(e) => {
                    // acpmux still holds the request (an allow needs the
                    // person's decision proof, which a chat reply never
                    // carries): keep it, so a deny or a newer message still
                    // answers it, and say so rather than leave the turn
                    // waiting in silence.
                    let text = format!(
                        "That {} was not accepted, so {} is still waiting: {e}. Use Allow on the card, or reply deny or send a new message to skip it.",
                        answer.as_str(),
                        pending.tool
                    );
                    let key = format!(
                        "approval:{}:undelivered:{}",
                        pending.permission_id, message.seq
                    );
                    self.say_about(&pending, &key, &text);
                    self.approvals.insert(k, pending);
                    return;
                }
            }
        }
    }

    /// Denies the running turn's pending approvals (`why` is the trace's
    /// approver); children's stay for a person.
    pub(super) fn deny_pending(&mut self, why: &str) {
        let (turn, children): (Vec<Pending>, Vec<Pending>) =
            self.approvals.drain(..).partition(|p| p.child.is_none());
        self.approvals.extend(children);
        for pending in turn {
            // A deny that does not land has no better answer to try.
            let _ = self.respond(&pending, Answer::Deny, why, None);
            self.cancel_card(&pending.permission_id);
        }
    }

    fn respond(
        &mut self,
        pending: &Pending,
        answer: Answer,
        approver: &str,
        install: Option<&str>,
    ) -> Result<(), String> {
        let result = self.answer_acpmux(pending, answer, approver);
        let option = option_for(&pending.request, answer);
        self.trace_approval(pending, answer, option, approver, install, result.is_ok());
        result
    }

    /// Answers acpmux and logs it; the caller records the trace once.
    fn answer_acpmux(
        &mut self,
        pending: &Pending,
        answer: Answer,
        approver: &str,
    ) -> Result<(), String> {
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
        result
    }

    /// Records one approval decision in the trace.
    fn trace_approval(
        &self,
        pending: &Pending,
        answer: Answer,
        option: Option<String>,
        approver: &str,
        install: Option<&str>,
        delivered: bool,
    ) {
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
                "delivered": delivered,
            });
            if let Err(e) = crate::approval::record(dir, fields) {
                (self.log)(&format!("recording an approval in the trace: {e}"));
            }
        }
    }
}

/// Whether acpmux's refusal says it no longer holds the request (answered
/// elsewhere, or its session ended): the approval is settled.
fn settled(error: &str) -> bool {
    error.contains("no pending permission") || error.contains("not_found")
}
