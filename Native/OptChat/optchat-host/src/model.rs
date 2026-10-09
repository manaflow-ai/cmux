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
    /// (single-flight). A model that cannot tell calls it with a reply, never
    /// after a failure (a failed call may have written nothing).
    fn call_started(
        &self,
        request: &CompactRequest,
        followups: &[Followup],
        started: &dyn Fn(),
    ) -> Result<Reply, ModelError> {
        let reply = self.call(request, followups);
        if reply.is_ok() {
            started();
        }
        reply
    }

    /// The node's conversation is over (built, or failed until its retry):
    /// a model that keeps a conversation open between calls (an acpmux
    /// session) closes it here. Called once per `run_node`.
    fn end(&self, _request: &CompactRequest) {}
}

/// An API error's class, read from a failed call's text (Claude Code's
/// "API Error: 400 {...}", the Messages API route's "HTTP 400: {...}"): its
/// status code, its error type, and the head of its message. No request
/// body is in it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ErrorClass {
    pub status: u16,
    pub kind: Option<String>,
    pub detail: Option<String>,
}

/// Longest message head an `ErrorClass` keeps.
const DETAIL_BYTES: usize = 120;

impl ErrorClass {
    /// A request error the same call repeats on every try: a 4xx but 408
    /// (timeout) and 429 (rate limit), which pass.
    pub fn permanent(&self) -> bool {
        (400..500).contains(&self.status) && self.status != 408 && self.status != 429
    }
}

impl fmt::Display for ErrorClass {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.status)?;
        if let Some(kind) = &self.kind {
            write!(f, " {kind}")?;
        }
        if let Some(detail) = &self.detail {
            write!(f, ": {detail}")?;
        }
        Ok(())
    }
}

/// The class of `message`, when it names an HTTP status.
pub fn error_class(message: &str) -> Option<ErrorClass> {
    let status = ["API Error: ", "HTTP "].iter().find_map(|lead| {
        let at = message.find(lead)? + lead.len();
        let digits = message.get(at..at + 3)?;
        digits
            .bytes()
            .all(|b| b.is_ascii_digit())
            .then(|| digits.parse().ok())
            .flatten()
    })?;
    // The error object's type (`"type":"invalid_request_error"`) and message.
    let field = |name: &str| -> Option<String> {
        let start = message.find("\"error\"")?;
        let rest = &message[start..];
        let key = format!("\"{name}\":\"");
        let at = rest.find(&key)? + key.len();
        let end = rest[at..].find('"')?;
        Some(rest[at..at + end].to_owned())
    };
    let kind = field("type").filter(|k| k != "error");
    let detail = field("message").map(|m| optchat_core::cut_at_bytes(&m, DETAIL_BYTES).to_owned());
    Some(ErrorClass {
        status,
        kind,
        detail,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_error_is_permanent_and_a_rate_limit_is_not() {
        let e = error_class(r#"API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"cache_control.ttl: wrong order"}}"#).unwrap();
        assert_eq!(e.to_string(), "400 invalid_request_error: cache_control.ttl: wrong order");
        assert!(e.permanent());
        assert!(!error_class("HTTP 429: slow down").unwrap().permanent());
        assert!(!error_class("API Error: 529 overloaded").unwrap().permanent());
        assert!(!error_class("API Error: 408 timeout").unwrap().permanent());
        assert_eq!(error_class("the acpmux connection was lost"), None);
    }
}
