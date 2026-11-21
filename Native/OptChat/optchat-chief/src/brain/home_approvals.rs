//! Home delivery for hidden local owner subagents only. The conversation
//! owner's acknowledgement establishes delivery; from then on the request
//! waits for the person's Allow or Deny and is never denied for a deadline.
use super::Brain;
use crate::state::PendingPermission;
use cmux_conversation::{
    Message, Op, Part, PreviewFormat, Question, QuestionHarness, QuestionItem, QuestionOption,
    QuestionPreview, QuestionState,
};
use sha2::{Digest, Sha256};

fn digest(request: &serde_json::Value) -> String {
    format!("{:x}", Sha256::digest(request.to_string().as_bytes()))
}

/// Conversation idempotency keys are bounded to 128 bytes, while acpmux
/// session and permission ids can both be UUIDs. Hash the whole binding.
fn home_key(session: &str, pending: &PendingPermission) -> String {
    format!(
        "home-approval:{}",
        digest(&serde_json::json!([session, pending.id, pending.request]))
    )
}

fn card(session: &str, id: &str, pending: &PendingPermission) -> Question {
    let snapshot = pending.request.to_string();
    Question {
        harness: QuestionHarness::Chief,
        session: session.to_owned(),
        permission: Some(pending.id.clone()),
        agent: Some(id.to_owned()),
        // Stable card identity; the app canonicalizes the full JSON snapshot
        // itself before comparing pendingAsk, and answerOnce re-reads again.
        items: vec![QuestionItem {
            id: format!("approval:{}", digest(&pending.request)),
            header: None,
            prompt: format!("{id}: {}", crate::approval::tool_name(&pending.request)),
            options: vec![
                QuestionOption {
                    id: "allow".into(),
                    label: "Allow once".into(),
                    detail: None,
                    preview: Some(QuestionPreview {
                        text: snapshot,
                        format: PreviewFormat::Monospace,
                    }),
                },
                QuestionOption {
                    id: "deny".into(),
                    label: "Deny".into(),
                    detail: None,
                    preview: None,
                },
            ],
            multi_select: false,
            allows_other: false,
        }],
        state: QuestionState::Pending,
    }
}

impl Brain {
    pub(super) fn home_approvals_available(&self) -> bool {
        self.summary.as_ref().is_some_and(|summary| {
            summary.owner == cmux_conversation::OWNER_LOCAL
                && self.state.conversation.as_deref() == Some(summary.id.as_str())
        })
    }

    pub(super) fn reconcile_home_approvals(&mut self) {
        // On startup acpmux can connect before the conversation owner. Wait
        // for that owner's summary before retiring an existing local card.
        if self.summary.is_none() {
            return;
        }
        let on = self.home_approvals_available();
        let pending: Vec<String> = self
            .state
            .spawns
            .values()
            .flat_map(|r| &r.subs)
            .filter(|s| {
                s.permission
                    .as_ref()
                    .is_some_and(|p| !p.home_closed && p.home_message.is_some())
            })
            .map(|s| s.id.clone())
            .collect();
        if on {
            // acpmux may have connected first. Once the local conversation
            // owner is known, deliver any eligible request seen before it.
            let waiting: Vec<String> = self
                .state
                .spawns
                .values()
                .flat_map(|r| &r.subs)
                .filter(|s| {
                    s.permission
                        .as_ref()
                        .is_some_and(|p| !p.home_closed && p.home_message.is_none())
                })
                .map(|s| s.id.clone())
                .collect();
            for id in waiting {
                self.rewatch_permission(&id);
            }
            return;
        }
        for id in pending {
            self.cancel_home_approval(&id);
            if let Some(p) = self.state.sub_mut(&id).and_then(|s| s.permission.as_mut()) {
                p.home_closed = true;
                p.home_message = None;
            }
            self.rewatch_permission(&id);
        }
        let waiting: Vec<String> = self
            .state
            .spawns
            .values()
            .flat_map(|r| &r.subs)
            .filter(|s| s.permission.is_some())
            .map(|s| s.id.clone())
            .collect();
        for id in waiting {
            self.rewatch_permission(&id);
        }
        self.save();
        self.flush_outbox();
    }

    pub(super) fn present_home_approval(&mut self, id: &str) {
        if !self.home_approvals_available() {
            return;
        }
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        // Never turn another person's floor, a peer, or a turn into a card.
        if sub.peer.is_some()
            || sub.workspace.is_some()
            || sub.policy.as_deref() == Some(crate::approval::ASK)
        {
            return;
        }
        let (Some(session), Some(pending)) = (sub.session_id.as_deref(), sub.permission.as_ref())
        else {
            return;
        };
        if pending.home_message.is_some() || pending.home_closed {
            return;
        }
        // Never hide part of the effect being authorized or present an agent
        // question as permission. Larger requests stay in the workspace path.
        if pending.request.to_string().len() > cmux_conversation::MAX_QUESTION_PREVIEW_BYTES
            || pending
                .request
                .pointer("/toolCall/_meta/acpmux/question")
                .is_some()
            || crate::approval::tool_name(&pending.request) == "AskUserQuestion"
            || crate::approval::tool_name(&pending.request).len() > 1000
        {
            return;
        }
        // Only ordinary permissions with both one-shot decisions can be answered here.
        let options = pending
            .request
            .get("options")
            .and_then(serde_json::Value::as_array);
        let once = |kind| {
            options.is_some_and(|options| options.iter().filter(|o| o["kind"] == kind).count() == 1)
        };
        if !once("allow_once") || !once("reject_once") {
            return;
        }
        let key = home_key(session, pending);
        if self
            .state
            .outbox
            .iter()
            .any(|entry| entry.idempotency_key == key)
        {
            return;
        }
        let question = card(session, id, pending);
        self.state.outbox.push(super::op_entry(
            conversation,
            &key,
            Op::MessageSend {
                client_msg_id: key.clone(),
                parts: vec![Part::Question(question)],
                reply_to: None,
                answers: vec![],
                answers_pending: vec![],
                thread_root: None,
            },
        ));
        self.save();
        self.flush_outbox();
    }

    /// Whether `id`'s pending request has a Home card, sent or on its way.
    pub(super) fn home_approval_queued(&self, id: &str) -> bool {
        let Some((_, sub)) = self.state.sub(id) else {
            return false;
        };
        let (Some(session), Some(pending)) = (sub.session_id.as_deref(), sub.permission.as_ref())
        else {
            return false;
        };
        if pending.home_closed {
            return false;
        }
        let key = home_key(session, pending);
        pending.home_message.is_some()
            || self
                .state
                .outbox
                .iter()
                .any(|entry| entry.idempotency_key == key)
    }

    /// Only an acknowledgement of our exact durable send can establish delivery.
    pub(super) fn home_approval_posted(
        &mut self,
        conversation: &str,
        key: &str,
        op: &Op,
        message: &Message,
    ) {
        let Op::MessageSend { parts, .. } = op else {
            return;
        };
        if !key.starts_with("home-approval:")
            || self.state.conversation.as_deref() != Some(conversation)
            || message.parts != *parts
        {
            return;
        }
        let [Part::Question(question)] = parts.as_slice() else {
            return;
        };
        let live = self.state.sub_by_session(&question.session).and_then(|id| {
            let (_, sub) = self.state.sub(&id)?;
            let pending = sub.permission.as_ref()?;
            (sub.peer.is_none()
                && sub.policy.as_deref() != Some(crate::approval::ASK)
                && *question == card(&question.session, &id, pending))
            .then_some(id)
        });
        let can_show = self.home_approvals_available()
            && live.as_ref().is_some_and(|id| {
                self.state
                    .sub(id)
                    .unwrap()
                    .1
                    .permission
                    .as_ref()
                    .is_some_and(|p| !p.home_closed)
            });
        if can_show {
            let id = live.expect("a matching live request");
            let pending = self
                .state
                .sub_mut(&id)
                .unwrap()
                .permission
                .as_mut()
                .unwrap();
            pending.home_message = Some(message.id.clone());
            // The card is in Home: the request waits for the person's click
            // (or the Chief's deny or steer), never for a deadline (Leo, 2026-11-03).
            let permission = pending.id.clone();
            self.forget_unanswered(&question.session, &permission);
        } else {
            if let Some(id) = live {
                // An unavailable late ACK must never become readiness on a ledger
                // replay after ownership changes. Retire this exact snapshot forever.
                if let Some(pending) = self
                    .state
                    .sub_mut(&id)
                    .and_then(|sub| sub.permission.as_mut())
                {
                    pending.home_closed = true;
                    pending.home_message = None;
                }
            }
            // A transport retry can deliver after the request ended or changed.
            // The durable send itself is the tombstone: a stale ACK retires it.
            self.end_home_card(message.id.clone(), question.clone(), false);
        }
        self.save();
    }

    pub(super) fn cancel_home_approval(&mut self, id: &str) {
        self.end_home_approval(id, false);
    }

    pub(super) fn end_home_approval(&mut self, id: &str, allow_app_record: bool) {
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        let (Some(session), Some(pending)) = (sub.session_id.as_deref(), sub.permission.as_ref())
        else {
            return;
        };
        let question = card(session, id, pending);
        let message = pending.home_message.clone();
        let key = home_key(session, pending);
        // Untried sends cannot have been delivered. Attempted sends keep the
        // identical retry body; their ACK above closes any late card.
        self.state
            .outbox
            .retain(|entry| entry.attempted || entry.idempotency_key != key);
        if let Some(message) = message {
            self.end_home_card(message, question, allow_app_record);
        }
        self.save();
    }

    fn end_home_card(
        &mut self,
        message_id: String,
        mut question: Question,
        allow_app_record: bool,
    ) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        question.state = QuestionState::Cancelled;
        let key = format!("home-approval-ended:{message_id}");
        if self
            .state
            .outbox
            .iter()
            .any(|entry| entry.idempotency_key == key)
        {
            return;
        }
        let mut entry = super::op_entry(
            conversation,
            &key,
            Op::MessageEdit {
                message_id,
                parts: vec![Part::Question(question)],
            },
        );
        // The app answers acpmux before recording Allow/Deny. Give that write
        // time to arrive; the owner's question reducer refuses to cancel an
        // already answered card, so this can never replace a recorded decision.
        if allow_app_record {
            entry.not_before = Some(super::now_ms() + 5_000);
        }
        self.state.outbox.push(entry);
    }
}
