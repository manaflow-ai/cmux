//! One exit-code table and one error envelope for every command.
//!
//! Exit codes: 0 ok, 1 runtime or agent error, 2 usage, 3 timeout, 4 no
//! such session, 5 every permission in the turn was denied or the host
//! refused a new session (`admission_refused`), 130 interrupted. `code`
//! is the small stable set orchestrators branch on; `detail` is free text
//! for diagnostics, or the daemon's own `reason` for a refusal that carries one (then `data` holds the daemon's error data, such
//! as `cwd_missing` with the missing `cwd`).

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
    /// The process's exit status when it is not `code`'s: a command another program ran for this
    /// one (the send relay, `send_relay.rs`) exits with that program's status.
    pub exit: Option<i32>,
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
            exit: None,
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
    pub fn with_exit(mut self, status: i32) -> Self {
        self.exit = Some(status);
        self
    }
    /// The status the process exits with.
    pub fn exit_status(&self) -> i32 {
        self.exit.unwrap_or(self.code as i32)
    }
    pub fn with_data(mut self, data: serde_json::Value) -> Self {
        self.data = Some(data);
        self
    }
    /// JSON envelope for stderr under --json.
    pub fn envelope(&self) -> serde_json::Value {
        let mut envelope = serde_json::json!({"error": {"code": self.code.name(), "exit": self.exit_status(), "detail": self.detail, "message": self.message, "sessionId": self.session_id, "promptId": self.prompt_id, "retryable": self.retryable}});
        if let Some(data) = &self.data {
            envelope["error"]["data"] = data.clone();
            for key in ["errorKind", "recovery"] {
                if let Some(v) = data.get(key) {
                    envelope["error"][key] = v.clone();
                }
            }
        }
        envelope
    }

    /// What to do about it (`recovery.rs`), when the daemon said.
    pub fn recovery(&self) -> Option<&str> {
        self.data.as_ref()?.get("recovery")?.as_str()
    }

    /// The text-mode report: `acpmux: <code>: <message>`, then what to do on its own line.
    pub fn text(&self) -> String {
        let mut text = format!("acpmux: {}: {}", self.code.name(), self.message);
        if let Some(recovery) = self.recovery() {
            text.push_str(&format!("\n  {recovery}"));
        }
        text
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
    let data = daemon.and_then(|d| d.0.data.as_ref());
    if let Some(data) = data
        && let Some(reason) = data["reason"].as_str()
    {
        // A host that refuses a new session exits 5, as lane-place does
        // when no host qualifies (`hub/admission.rs`).
        let code = if reason == crate::hub::admission::REASON {
            Code::PermissionDenied
        } else if daemon.is_some_and(|d| d.0.code == -32602) {
            Code::Usage
        } else {
            Code::Runtime
        };
        let mut app = AppError::new(code, reason, msg);
        app.retryable = data["retryable"] == true;
        app.data = Some(data.clone());
        return app;
    }
    let mut app = classify_message(e, msg);
    // A typed error (`recovery.rs`) names its kind as the detail and says what to do; its exit
    // code stays the one its message gives.
    if let Some(data) = data
        && let Some(kind) = data["errorKind"].as_str()
    {
        app.detail = kind.to_owned();
        app.data = Some(data.clone());
    }
    app
}

/// The exit code and detail an error's message gives.
fn classify_message(e: &anyhow::Error, msg: String) -> AppError {
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

/// Print and exit. Text mode prints `acpmux: <code>: <message>` and what to do; JSON mode
/// prints the envelope, both on stderr, nothing on stdout.
pub fn exit_with(e: &anyhow::Error, json_out: bool) -> ! {
    let app = classify(e);
    if json_out {
        eprintln!("{}", app.envelope());
    } else {
        eprintln!("{}", app.text());
    }
    std::process::exit(app.exit_status());
}

#[cfg(test)]
mod typed_error_tests {
    use super::*;
    use crate::rpc::RpcError;
    use serde_json::json;

    fn daemon(e: RpcError) -> anyhow::Error {
        anyhow::Error::from(crate::client::DaemonError(e))
    }

    /// A typed error prints its sentence and, on the next line, what to do; the JSON envelope
    /// carries the kind and the recovery beside the daemon's data.
    #[test]
    fn a_typed_error_prints_the_sentence_and_the_action() {
        let e = daemon(RpcError::internal("No space left on device (os error 28)").with_data(json!({
            "errorKind": "disk.full",
            "recovery": "The disk is full. Free space on the disk that holds /h: 0.1 GB free of 252 GB.",
            "details": {"path": "/h", "freeBytes": 100_000_000u64, "totalBytes": 252_000_000_000u64},
        })));
        let app = classify(&e);
        assert_eq!(app.detail, "disk.full");
        assert_eq!(
            app.text(),
            "acpmux: runtime: No space left on device (os error 28)\n  The disk is full. Free space on the disk that holds /h: 0.1 GB free of 252 GB."
        );
        let env = app.envelope();
        assert_eq!(env["error"]["errorKind"], "disk.full");
        assert!(env["error"]["recovery"].as_str().unwrap().starts_with("The disk is full."));
        assert_eq!(env["error"]["data"]["details"]["path"], "/h");
    }

    /// A refusal with a reason keeps that reason as its detail and still prints the action.
    #[test]
    fn a_peer_refusal_keeps_its_reason_and_prints_the_action() {
        let mut e = RpcError::internal("peer_unreachable: b (reconnecting, last seen 40s ago: connect timed out)")
            .with_data(json!({"reason": "peer_unreachable", "retryable": true, "peer": "b", "lastSeen": 1_000u64}));
        crate::recovery::annotate(&mut e, None);
        let app = classify(&daemon(e));
        assert_eq!(app.detail, "peer_unreachable");
        assert!(app.retryable);
        let text = app.text();
        assert!(text.contains("\n  Check that b is on and online in `tailscale status`; `acpmux host doctor b` checks the link"), "{text}");
        assert_eq!(app.envelope()["error"]["errorKind"], "peer.unreachable");
        assert_eq!(
            app.envelope()["error"]["data"]["details"]["lastSeenAt"],
            "1970-01-01T00:00:01.000Z"
        );
    }

    /// The daemon refusing work while it shuts down says it is restarting.
    #[test]
    fn a_shutting_down_daemon_says_it_is_restarting() {
        let mut e = RpcError::internal(crate::hub::SHUTTING_DOWN);
        crate::recovery::annotate(&mut e, None);
        let app = classify(&daemon(e));
        assert_eq!(app.detail, "daemon.restarting");
        assert!(app.text().contains("\n  The daemon is restarting."), "{}", app.text());
    }

    /// A kind adds detail and never changes the exit code: a timeout still exits 3 and an
    /// unknown session 4 when the daemon typed the error.
    #[test]
    fn a_typed_error_keeps_its_exit_code() {
        let typed = |message: &str| {
            daemon(RpcError::internal(message).with_data(json!({
                "errorKind": "agent.exited",
                "recovery": "The agent stopped in the middle of the turn.",
                "details": {},
            })))
        };
        let app = classify(&typed("request timed out"));
        assert_eq!(app.code as i32, 3, "{:?}", app.envelope());
        assert_eq!(app.detail, "agent.exited");
        assert_eq!(app.recovery(), Some("The agent stopped in the middle of the turn."));
        let app = classify(&typed("unknown session s-1"));
        assert_eq!(app.code as i32, 4, "{:?}", app.envelope());
        assert_eq!(app.envelope()["error"]["errorKind"], "agent.exited");
    }

    /// An error with nothing to add prints as before.
    #[test]
    fn an_untyped_error_prints_as_before() {
        let mut e = RpcError::internal("something odd");
        crate::recovery::annotate(&mut e, None);
        assert!(e.data.is_none());
        assert_eq!(classify(&daemon(e)).text(), "acpmux: runtime: something odd");
    }
}
