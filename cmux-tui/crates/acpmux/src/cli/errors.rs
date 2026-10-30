//! One exit-code table and one error envelope for every command.
//!
//! Exit codes: 0 ok, 1 runtime or agent error, 2 usage, 3 timeout, 4 no
//! such session, 5 every permission in the turn was denied, 130
//! interrupted. `code` is the small stable set orchestrators branch on;
//! `detail` is free text for diagnostics, or the daemon's own `reason` for a
//! refusal that carries one (then `data` holds the daemon's error data, such
//! as `cwd_missing` with the missing `cwd`).

use crate::no_panic::JsonExt;
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
    /// The daemon's error data, for a refusal with a `reason`.
    pub data: Option<serde_json::Value>,
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
            data: None,
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
        let mut envelope = serde_json::json!({"error": {"code": self.code.name(), "exit": self.code as i32, "detail": self.detail, "message": self.message, "sessionId": self.session_id, "promptId": self.prompt_id, "retryable": self.retryable}});
        if let Some(data) = &self.data {
            envelope.set_path(&["error", "data"], data.clone());
        }
        envelope
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
    let daemon = e.downcast_ref::<crate::client::DaemonError>();
    if let Some(data) = daemon.and_then(|d| d.0.data.as_ref())
        && let Some(reason) = data["reason"].as_str()
    {
        let code =
            if daemon.is_some_and(|d| d.0.code == -32602) { Code::Usage } else { Code::Runtime };
        let mut app = AppError::new(code, reason, msg);
        app.retryable = data["retryable"] == true;
        app.data = Some(data.clone());
        return app;
    }
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

/// A command that already printed its whole result, and whose process ends
/// with this exit code (a wait that timed out, a compare whose worst run
/// failed, a host update that failed somewhere). It travels as the command's
/// error so the command returns to its caller instead of ending the process
/// itself; [`exit_with`] then prints nothing more.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Reported(pub i32);

impl fmt::Display for Reported {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "the command reported its result and exits with {}", self.0)
    }
}

impl std::error::Error for Reported {}

/// Prints `e` for the person (nothing for [`Reported`]) and returns the exit
/// code it maps to. Text mode prints `acpmux: <code>: <message>`; JSON mode
/// prints the envelope, both on stderr, nothing on stdout.
pub fn report(e: &anyhow::Error, json_out: bool) -> i32 {
    if let Some(Reported(code)) = e.downcast_ref::<Reported>() {
        return *code;
    }
    let app = classify(e);
    if json_out {
        eprintln!("{}", app.envelope());
    } else {
        eprintln!("acpmux: {}: {}", app.code.name(), app.message);
    }
    app.code as i32
}

/// Print and exit: [`report`], then the process ends with its code.
pub fn exit_with(e: &anyhow::Error, json_out: bool) -> ! {
    std::process::exit(report(e, json_out));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reported_result_ends_with_its_own_code() {
        // `wait` timed out (3) after printing its rows: no envelope, the code it chose.
        let error = anyhow::Error::new(Reported(3)).context("acpmux wait");
        assert_eq!(report(&error, true), 3);
        assert_eq!(report(&anyhow::Error::new(Reported(1)), false), 1);
    }

    #[test]
    fn any_other_error_ends_with_its_class_code() {
        assert_eq!(report(&AppError::no_session("x").into(), false), Code::NoSession as i32);
        assert_eq!(report(&anyhow::anyhow!("boom"), true), Code::Runtime as i32);
    }
}
