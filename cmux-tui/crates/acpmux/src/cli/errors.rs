//! One exit-code table and one error envelope for every command.
//!
//! Exit codes: 0 ok, 1 runtime or agent error, 2 usage, 3 timeout, 4 no
//! such session, 5 every permission in the turn was denied or the host
//! refused a new session (`admission_refused`), 6 `session stop --if-idle`
//! refused: the session is not idle (`busy`) or its revision moved
//! (`revision_moved`, `hub/stop_if_idle.rs`), 130 interrupted. `code`
//! is the small stable set orchestrators branch on; `detail` is free text
//! for diagnostics, or the daemon's own `reason` for a refusal that carries one (then `data` holds the daemon's error data, such
//! as `cwd_missing` with the missing `cwd`).

use cmux_json::JsonSet as _;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Code {
    Runtime = 1,
    Usage = 2,
    Timeout = 3,
    NoSession = 4,
    PermissionDenied = 5,
    /// A conditional stop refused (`hub/stop_if_idle.rs`): nothing was stopped.
    NotIdle = 6,
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
            Code::NotIdle => "not_idle",
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
    /// [`Self::no_session`] for a daemon refusal of `key`, with the names the daemon said
    /// `key` nearly matched (`session_name::not_found`'s `data.candidates`), so the caller
    /// can pick one without listing every session.
    pub fn no_session_from(key: &str, e: &anyhow::Error) -> Self {
        let candidates: Vec<String> = e
            .downcast_ref::<crate::client::DaemonError>()
            .and_then(|d| d.0.data.as_ref())
            .and_then(|d| d.get("candidates")?.as_array())
            .map(|c| c.iter().filter_map(|n| n.as_str().map(str::to_owned)).collect())
            .unwrap_or_default();
        if candidates.is_empty() {
            return Self::no_session(key);
        }
        Self::new(
            Code::NoSession,
            "no_session",
            format!(
                "no session matches {key:?}; close matches: {}; use one of those names, or run `acpmux ls`",
                crate::session_name::candidate_list(&candidates)
            ),
        )
        .with_data(serde_json::json!({"candidates": candidates}))
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
            envelope.set_path(&["error", "data"], data.clone());
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
        } else if daemon.is_some_and(|d| d.0.code == crate::hub::stop_if_idle::NOT_IDLE_CODE) {
            Code::NotIdle
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
    // The names a key nearly matched (`session_name.rs`) reach the JSON envelope.
    if let Some(data) = data
        && data.get("candidates").is_some()
        && app.data.is_none()
    {
        app.data = Some(data.clone());
    }
    app
}

/// The exit code and detail an error's message gives.
fn classify_message(e: &anyhow::Error, msg: String) -> AppError {
    let lower = msg.to_lowercase();
    if e.is::<crate::client::TransportClosed>() {
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
        // A name several sessions answer to: the exact command for each (`hub/key_route.rs`).
        if app.detail == crate::hub::key_route::AMBIGUOUS
            && let Some(data) = &app.data
        {
            let args: Vec<String> = std::env::args().collect();
            let lines = crate::cli::resolve::choice_commands(&args, data);
            for line in lines.iter().take(10) {
                eprintln!("  {line}");
            }
            if lines.len() > 10 {
                eprintln!("  … and {} more (`--json` lists every one)", lines.len() - 10);
            }
        }
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

    /// A refused `session stop --if-idle` exits 6 with the daemon's reason as its detail, and
    /// the envelope keeps the revision the caller reads again.
    #[test]
    fn a_refused_conditional_stop_exits_6_with_its_reason() {
        use crate::hub::stop_if_idle::{BUSY, NOT_IDLE_CODE, REVISION_MOVED};
        for (reason, busy_with) in [(BUSY, json!("turn")), (REVISION_MOVED, json!(null))] {
            let e = RpcError::new(NOT_IDLE_CODE, "session is not idle: not stopped").with_data(
                json!({"reason": reason, "busyWith": busy_with, "revision": 41u64, "sessionId": "s", "retryable": true}),
            );
            let app = classify(&daemon(e));
            assert_eq!(app.code, Code::NotIdle);
            assert_eq!(app.exit_status(), 6);
            assert_eq!(app.detail, reason);
            assert!(app.retryable);
            let env = app.envelope();
            assert_eq!(env["error"]["code"], "not_idle");
            assert_eq!(env["error"]["data"]["revision"], 41);
        }
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

    /// The names the daemon said a key nearly matched reach the message and the envelope;
    /// the refusal stays no_session (exit 4), so the send relay still takes it.
    #[test]
    fn a_no_session_refusal_names_the_close_matches() {
        let refused = daemon(crate::session_name::not_found("mac-ci", &["a/mac-ci-3".into()]));
        let app = AppError::no_session_from("mac-ci", &refused);
        assert_eq!((app.code, app.detail.as_str()), (Code::NoSession, "no_session"));
        assert!(app.message.contains("close matches: a/mac-ci-3"), "{}", app.message);
        assert_eq!(app.envelope()["error"]["data"]["candidates"], json!(["a/mac-ci-3"]));
        let classified = classify(&refused);
        assert_eq!(classified.code, Code::NoSession);
        assert_eq!(classified.envelope()["error"]["data"]["candidates"], json!(["a/mac-ci-3"]));
        let plain = AppError::no_session_from(
            "x",
            &daemon(RpcError::not_found("no session matches \"x\"")),
        );
        assert_eq!(plain.message, AppError::no_session("x").message);
        assert!(crate::cli::send_relay::no_such_session(&app.into()));
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
