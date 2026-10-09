use std::fmt;

use optchat_core::CompactRequest;

/// One assistant answer of a compactor conversation.
#[derive(Clone, Debug, PartialEq)]
pub struct Reply {
    /// The answer's text (text blocks joined); the size loop measures this.
    pub text: String,
    /// The assistant message content exactly as the API returned it, sent back
    /// verbatim in the next step of the same conversation (thinking blocks and
    /// signatures included, section 8). `Null` when the client has none.
    pub content: serde_json::Value,
}

impl Reply {
    /// A reply with no raw content (fakes, clients without blocks).
    pub fn text(text: impl Into<String>) -> Reply {
        Reply {
            text: text.into(),
            content: serde_json::Value::Null,
        }
    }
}

/// One size-loop round (section 4.3): the model's reply, then the "That line
/// is N bytes" message the host answered with, in the same conversation.
#[derive(Clone, Debug, PartialEq)]
pub struct Followup {
    pub reply: Reply,
    pub retry: String,
}

/// A failed model call: the node fails and is retried after `RETRY`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelError {
    pub message: String,
    /// The model declined (`stop_reason: refusal`). The same call would be
    /// declined again, so the compactor asks its fallback model instead of
    /// only waiting `RETRY` and repeating it.
    pub refused: bool,
}

impl ModelError {
    pub fn new(message: impl Into<String>) -> ModelError {
        ModelError {
            message: message.into(),
            refused: false,
        }
    }

    pub fn refusal(message: impl Into<String>) -> ModelError {
        ModelError {
            message: message.into(),
            refused: true,
        }
    }
}

impl fmt::Display for ModelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ModelError {}

/// The compactor's model. Called from worker threads, never with the chat's
/// lock held, so a call may block for as long as the model takes.
pub trait CompactModel: Send + Sync {
    /// The next assistant reply in the conversation: `request` (system, then
    /// one user message of the context and step blocks), then each followup's
    /// reply and retry text, oldest first. No tools.
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError>;

    /// `call`, and `started` once the response has begun (the API's
    /// `message_start`, a harness's first streamed output): from then on the
    /// request's cache entry exists, so a call that waits to read it may go
    /// (single-flight). A model that cannot tell calls it with the reply.
    fn call_started(
        &self,
        request: &CompactRequest,
        followups: &[Followup],
        started: &dyn Fn(),
    ) -> Result<Reply, ModelError> {
        let reply = self.call(request, followups);
        started();
        reply
    }

    /// The node's conversation is over (built, or failed until its retry):
    /// a model that keeps a conversation open between calls (an acpmux
    /// session) closes it here. Called once per `run_node`.
    fn end(&self, _request: &CompactRequest) {}
}
