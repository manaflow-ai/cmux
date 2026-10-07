//! One exit-code table and one error envelope for every command.
//!
//! Exit codes: 0 ok, 1 runtime or agent error, 2 usage, 3 timeout, 4 no
//! such session, 5 every permission in the turn was denied, 130
//! interrupted. `code` is the small stable set orchestrators branch on;
//! `detail` is free text for diagnostics.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Code {
    Runtime = 1,
    Usage = 2,
    Timeout = 3,
    NoSession = 4,
    PermissionDenied = 5,
    /// Reserved: a SIGINT ends the process with the shell's own 130.
    #[allow(dead_code)]
    Interrupted = 130,
}

impl Code {
    pub fn name(self) -> &'static str {
        match self {
            Code::Runtime => "runtime",
            Code::Usage => "usage",
            Code::Timeout => "timeout",
            Code::NoSession => "no_session",
            Code::PermissionDenied => "permission_denied",
            Code::Interrupted => "interrupted",
        }
    }
}

#[derive(Debug, Clone)]
pub struct AppError {
    pub code: Code,
    pub detail: String,
    pub message: String,
    pub session_id: Option<String>,
    /// The client prompt id of a prompt whose outcome is unknown; sending
    /// it again (`--prompt-id`) never runs a second turn.
    pub prompt_id: Option<String>,
    pub retryable: bool,
}

impl AppError {
    pub fn new(code: Code, detail: &str, message: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
            message: message.into(),
            session_id: None,
            prompt_id: None,
            retryable: false,
        }
    }
    pub fn usage(message: impl Into<String>) -> Self {
        Self::new(Code::Usage, "usage", message)
    }
    pub fn timeout(message: impl Into<String>) -> Self {
        Self::new(Code::Timeout, "timeout", message)
    }
    pub fn no_session(key: &str) -> Self {
        Self::new(
            Code::NoSession,
            "no_session",
            format!("no session matches {key:?}; run `acpmux ls` or `acpmux ensure {key}`"),
        )
    }
    pub fn with_session(mut self, id: &str) -> Self {
        self.session_id = Some(id.to_owned());
        self
    }
    pub fn with_prompt(mut self, id: &str) -> Self {
        self.prompt_id = Some(id.to_owned());
        self
    }
    pub fn retryable(mut self) -> Self {
        self.retryable = true;
        self
    }
    /// JSON envelope for stderr under --json.
    pub fn envelope(&self) -> serde_json::Value {
        serde_json::json!({"error": {"code": self.code.name(), "exit": self.code as i32, "detail": self.detail, "message": self.message, "sessionId": self.session_id, "promptId": self.prompt_id, "retryable": self.retryable}})
    }
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for AppError {}

/// Map any error to (exit code, envelope). Daemon "not found" errors become
/// exit 4; everything else unknown is a runtime error.
pub fn classify(e: &anyhow::Error) -> AppError {
    if let Some(app) = e.downcast_ref::<AppError>() {
        return app.clone();
    }
    let msg = e.to_string();
    let lower = msg.to_lowercase();
    if lower.contains("connection closed") {
        return AppError::new(Code::Runtime, "daemon_closed", msg).retryable();
    }
    if lower.contains("no session matches")
        || lower.contains("unknown session")
        || lower.contains("not found") && lower.contains("session")
    {
        return AppError::new(Code::NoSession, "no_session", msg);
    }
    if e.downcast_ref::<crate::client::DaemonError>().is_some_and(|d| d.0.code == -32602) {
        return AppError::new(Code::Usage, "usage", msg);
    }
    if lower.contains("cursor_future")
        || lower.contains("cursor_expired")
        || lower.starts_with("usage:")
        || lower.contains("invalid params")
    {
        return AppError::new(Code::Usage, "usage", msg);
    }
    if lower.contains("timed out") || lower.contains("timeout") {
        return AppError::new(Code::Timeout, "timeout", msg);
    }
    let detail = if lower.contains("connection refused") || lower.contains("daemon") {
        "daemon_unreachable"
    } else if lower.contains("spawn") {
        "agent_spawn_failed"
    } else {
        "error"
    };
    AppError::new(Code::Runtime, detail, msg)
}

/// Print and exit. Text mode prints `acpmux: <code>: <message>`; JSON mode
/// prints the envelope, both on stderr, nothing on stdout.
pub fn exit_with(e: &anyhow::Error, json_out: bool) -> ! {
    let app = classify(e);
    if json_out {
        eprintln!("{}", app.envelope());
    } else {
        eprintln!("acpmux: {}: {}", app.code.name(), app.message);
    }
    std::process::exit(app.code as i32);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_common_errors() {
        assert_eq!(classify(&anyhow::anyhow!("no session matches \"x\"")).code, Code::NoSession);
        assert_eq!(
            classify(&anyhow::anyhow!("cursor_future: afterSeq 9 is beyond the last event 3")).code,
            Code::Usage
        );
        assert_eq!(classify(&anyhow::anyhow!("turn timed out after 5s")).code, Code::Timeout);
        assert_eq!(classify(&anyhow::anyhow!("something broke")).code, Code::Runtime);
        let bad: anyhow::Error =
            crate::client::DaemonError(crate::rpc::RpcError::invalid_params("modeId is required"))
                .into();
        assert_eq!(classify(&bad).code, Code::Usage);
        assert_eq!(classify(&bad).message, "modeId is required");
        let closed = classify(&crate::client::closed_error("waiting", Some("abc 2026-01-01")));
        assert_eq!(closed.detail, "daemon_closed");
        assert!(closed.retryable);
        assert!(
            closed.message.contains("while waiting") && closed.message.contains("daemon.log"),
            "{}",
            closed.message
        );
        let app =
            AppError::new(Code::PermissionDenied, "all_denied", "every permission was denied")
                .with_session("abc");
        let e: anyhow::Error = app.clone().into();
        assert_eq!(classify(&e).code, Code::PermissionDenied);
        assert_eq!(app.envelope()["error"]["exit"], 5);
        assert_eq!(app.envelope()["error"]["sessionId"], "abc");
    }
}
