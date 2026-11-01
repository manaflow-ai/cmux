//! Explicit owner actions reopen reply obligations without posting another
//! person message. The brain serializes them with incoming messages and turns.

use cmux_chief::rules::{PAGE, message_text};
use cmux_conversation::Message;
use serde_json::{Value, json};

use super::{Brain, Phase, Source};

impl Brain {
    pub(super) fn owner_continue(&mut self) -> Value {
        if self.phase != Phase::Idle
            || !self.queue.is_empty()
            || self.resume_at.is_some()
            || self.orphan_wait.is_some()
        {
            return json!({"continued": false, "reason": "busy"});
        }
        let Some(stopped) = self.state.stopped_reply.take() else {
            return json!({"continued": false});
        };
        let mut ids = Vec::new();
        for mut awaiting in stopped.messages {
            ids.push(awaiting.id.clone());
            awaiting.tries = 0;
            awaiting.due_ms = None;
            awaiting.why = None;
            if !self.state.awaiting.iter().any(|a| a.id == awaiting.id) {
                self.state.awaiting.push(awaiting);
            }
        }
        super::turns::add_answers(&mut self.state.carry_answers, ids);
        self.save();
        self.queue(
            "[continue] The person pressed Continue after stopping you; pick up where you left off and answer the stopped messages.".into(),
            Source::OwnerAction { requires_approval: stopped.requires_approval },
        );
        json!({"continued": true})
    }

    pub(super) fn owner_retry(&mut self, id: &str) -> Value {
        if self.phase != Phase::Idle
            || !self.queue.is_empty()
            || self.resume_at.is_some()
            || self.orphan_wait.is_some()
        {
            return json!({"retried": false, "reason": "busy"});
        }
        let message = match self.retry_message(id) {
            Ok(Some(message)) => message,
            Ok(None) => return json!({"retried": false, "reason": "invalid_message"}),
            Err(()) => return json!({"retried": false, "reason": "unavailable"}),
        };
        let text = message_text(&message);
        let Some(daemon) = self.daemon.as_mut() else {
            return json!({"retried": false, "reason": "unavailable"});
        };
        let images = super::images::read_images(daemon.as_mut(), &message);
        let files =
            super::files::read_files(daemon.as_mut(), &message, &self.file.attachments_dir());
        let contents =
            super::files::logged_text(&super::images::logged_text(&text, &images), &files);
        self.state.awaiting.retain(|a| a.id != id);
        self.await_reply(&message, &text);
        super::turns::add_answers(&mut self.state.carry_answers, vec![id.into()]);
        self.state.stopped_reply = None;
        self.save();
        self.queue_with_images(
            format!("[retry] The person pressed Retry Reply for message {id}. Re-answer that message now, using its current contents:\n{contents}"),
            images,
            Source::OwnerAction { requires_approval: false },
        );
        json!({"retried": true})
    }

    /// Read from the conversation owner, including older pages: an arbitrary
    /// message ID must never select another conversation or a retracted post.
    fn retry_message(&mut self, id: &str) -> Result<Option<Message>, ()> {
        if id.trim().is_empty() {
            return Ok(None);
        }
        let conversation = self.state.conversation.as_deref().ok_or(())?;
        let daemon = self.daemon.as_mut().ok_or(())?;
        let (summary, mut page) = daemon.snapshot(conversation, PAGE).map_err(|_| ())?;
        loop {
            if let Some(message) = page.iter().find(|m| m.id == id) {
                return Ok((message.conversation == conversation
                    && message.retracted_at.is_none()
                    && self.settings.membership.is_owner_message(&summary, message))
                .then(|| message.clone()));
            }
            let Some(before) = page.iter().map(|m| m.seq).min().filter(|n| *n > 1) else {
                return Ok(None);
            };
            page = daemon.history(conversation, before, PAGE).map_err(|_| ())?;
            if page.iter().any(|m| m.seq >= before) {
                return Err(());
            }
        }
    }
}
