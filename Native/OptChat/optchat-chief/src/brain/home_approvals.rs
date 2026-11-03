//! Home delivery for hidden local owner subagents only. The conversation
//! owner's acknowledgement, not an enqueued send, retires the watchdog.
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
    pub(super) fn present_home_approval(&mut self, id: &str) {
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
        if pending.home_message.is_some() {
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
        let key = format!(
            "home-approval:{session}:{}:{}",
            pending.id,
            digest(&pending.request)
        );
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
        if let Some(id) = live {
            let pending = self
                .state
                .sub_mut(&id)
                .unwrap()
                .permission
                .as_mut()
                .unwrap();
            pending.home_message = Some(message.id.clone());
            let permission = pending.id.clone();
            self.forget_unanswered(&question.session, &permission);
        } else {
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
        let key = format!(
            "home-approval:{session}:{}:{}",
            pending.id,
            digest(&pending.request)
        );
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
