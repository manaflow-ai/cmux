//! What an agent reads when the Computer Use worker asked the person
//! (docs/computer-use-approvals.md, "The approval question").
//!
//! The worker decides; this only words its refusals. A call on an app outside
//! the session's manifest waits up to 2 minutes for the person's answer on a
//! protected collector (the cmux app's card, their phone, polkit, Windows
//! Hello). Without one it fails with `approval_timeout`, while the question
//! stays answerable for 10 minutes; a parallel call on the same app joins the
//! open question (`approval_pending`); a Deny is `approval_denied`. The text
//! says the person was asked and what to do now, never "retry in a loop".
//! `cmux mcp serve` (`computer_use_gate.rs`) uses the same words.

use serde_json::{Value, json};

/// A refusal the worker answered: `{"id", "ok": false, "error", "code"?}`.
/// The connection is fine; only this request did not run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerError {
    /// The worker's machine-readable reason (`approval_timeout`, ...).
    pub code: Option<String>,
    pub message: String,
    /// The target app's name, when the worker gave it (for the text only).
    pub app: Option<String>,
}

impl std::fmt::Display for WorkerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for WorkerError {}

impl WorkerError {
    /// Reads a refusal. The code is `code`, or `error.code` when `error` is
    /// an object, or the error text itself when it is a bare known code
    /// (`"approval_timeout"`, `"approval_timeout: …"`).
    pub fn from_reply(reply: &Value) -> Self {
        let error = &reply["error"];
        let message = error
            .as_str()
            .or_else(|| error["message"].as_str())
            .unwrap_or("the Computer Use helper failed")
            .to_owned();
        let code =
            reply["code"].as_str().or_else(|| error["code"].as_str()).map(str::to_owned).or_else(
                || {
                    let head = message.split([':', ' ']).next().unwrap_or_default();
                    ApprovalRefusal::from_code(head).map(|_| head.to_owned())
                },
            );
        let app = [&reply["app"], &reply["target"], &error["app"], &error["target"]]
            .iter()
            .find_map(|v| v["name"].as_str().or_else(|| v.as_str()))
            .map(plain_name)
            .filter(|name| !name.is_empty());
        WorkerError { code, message, app }
    }

    /// The approval refusal this is, if any.
    pub fn approval(&self) -> Option<ApprovalRefusal> {
        self.code.as_deref().and_then(ApprovalRefusal::from_code)
    }
}

/// A name shown in model text: printable, one line, at most 60 characters.
fn plain_name(name: &str) -> String {
    name.chars().filter(|c| !c.is_control()).take(60).collect::<String>().trim().to_owned()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalRefusal {
    /// The person did not answer within the call's 2 minutes.
    Timeout,
    /// The person chose Deny.
    Denied,
    /// A question about this app is already open for this session.
    Pending,
}

impl ApprovalRefusal {
    /// The worker's code, with or without the `computer_use.` prefix.
    pub fn from_code(code: &str) -> Option<Self> {
        match code.strip_prefix("computer_use.").unwrap_or(code) {
            "approval_timeout" => Some(Self::Timeout),
            "approval_denied" => Some(Self::Denied),
            "approval_pending" => Some(Self::Pending),
            _ => None,
        }
    }

    /// The tool error code agents and scripts read.
    pub fn code(self) -> &'static str {
        match self {
            Self::Timeout => "computer_use.approval_timeout",
            Self::Denied => "computer_use.approval_denied",
            Self::Pending => "computer_use.approval_pending",
        }
    }

    /// Whether calling again can work: after the person allows it.
    pub fn retryable(self) -> bool {
        !matches!(self, Self::Denied)
    }

    /// What the model reads: what happened, and what to do now.
    pub fn message(self, app: Option<&str>) -> String {
        let app = app.filter(|a| !a.is_empty()).unwrap_or("this app");
        match self {
            Self::Timeout => format!(
                "cmux asked the person on their Mac or phone whether you may use {app}, and they \
                 have not answered yet. The question stays open there for 10 minutes. Tell the \
                 person in one line that cmux is waiting for their answer, then continue with \
                 work that does not need {app}. Call this tool again once, after they say they \
                 allowed it; do not retry in a loop."
            ),
            Self::Pending => format!(
                "cmux is already asking the person whether you may use {app} (an earlier call \
                 asked). The question stays open on their Mac or phone for 10 minutes. Tell the \
                 person in one line that cmux is waiting for their answer, continue with other \
                 work, and call again only after they say they allowed it; do not retry in a loop."
            ),
            Self::Denied => format!(
                "The person denied this use of {app}. Do not use {app} again in this turn. Tell \
                 the person in one line what you could not do, then continue with the work that \
                 does not need it."
            ),
        }
    }

    /// The MCP tool result of this refusal: nothing ran.
    pub fn tool_result(self, app: Option<&str>) -> Value {
        let message = self.message(app);
        json!({
            "content": [{"type": "text", "text": message}],
            "isError": true,
            "structuredContent": {"error": {
                "code": self.code(),
                "message": message,
                "details": {"app": app},
                "retryable": self.retryable(),
            }},
        })
    }

    /// The refusal a tool result carries, with its app, if any.
    pub fn of_result(result: &Value) -> Option<(Self, Option<String>)> {
        if result["isError"] != json!(true) {
            return None;
        }
        let error = &result["structuredContent"]["error"];
        let refusal = Self::from_code(error["code"].as_str()?)?;
        Some((refusal, error["details"]["app"].as_str().map(str::to_owned)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_codes_are_read_from_every_reply_shape() {
        for reply in [
            json!({"id": 3, "ok": false, "code": "approval_timeout", "error": "no answer in 2 minutes"}),
            json!({"id": 3, "ok": false, "error": {"code": "approval_timeout", "message": "x"}}),
            json!({"id": 3, "ok": false, "error": "approval_timeout"}),
            json!({"id": 3, "ok": false, "error": "approval_timeout: no answer"}),
            json!({"id": 3, "ok": false, "code": "computer_use.approval_timeout", "error": "x"}),
        ] {
            assert_eq!(
                WorkerError::from_reply(&reply).approval(),
                Some(ApprovalRefusal::Timeout),
                "{reply}"
            );
        }
        let other = WorkerError::from_reply(&json!({"ok": false, "error": "target refused"}));
        assert_eq!(other.approval(), None);
        assert_eq!(other.message, "target refused");
    }

    #[test]
    fn the_app_name_is_plain_text_from_the_worker() {
        let reply = json!({"ok": false, "code": "approval_denied", "error": "denied",
            "target": {"name": "Safari\n\u{1b}[31m"}});
        assert_eq!(WorkerError::from_reply(&reply).app.as_deref(), Some("Safari[31m"));
    }

    #[test]
    fn each_refusal_says_the_person_was_asked_and_never_to_loop() {
        let timeout = ApprovalRefusal::Timeout.message(Some("Safari"));
        assert!(timeout.contains("asked the person on their Mac or phone"), "{timeout}");
        assert!(timeout.contains("10 minutes"), "{timeout}");
        assert!(timeout.contains("do not retry in a loop"), "{timeout}");
        let pending = ApprovalRefusal::Pending.message(None);
        assert!(pending.contains("already asking the person whether you may use this app"));
        assert!(pending.contains("do not retry in a loop"));
        let denied = ApprovalRefusal::Denied.message(Some("Notes"));
        assert!(denied.contains("The person denied this use of Notes"));
        assert!(!ApprovalRefusal::Denied.retryable());
    }

    #[test]
    fn a_tool_result_round_trips_its_refusal() {
        let result = ApprovalRefusal::Pending.tool_result(Some("Mail"));
        assert_eq!(result["isError"], true);
        assert_eq!(result["structuredContent"]["error"]["code"], "computer_use.approval_pending");
        assert_eq!(
            ApprovalRefusal::of_result(&result),
            Some((ApprovalRefusal::Pending, Some("Mail".into())))
        );
        assert_eq!(ApprovalRefusal::of_result(&json!({"content": []})), None);
    }
}
