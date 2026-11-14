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
        let data = e.downcast_ref::<crate::client::DaemonError>().and_then(|d| d.0.data.as_ref());
        let candidates: Vec<String> = data
            .and_then(|d| d.get("candidates")?.as_array())
            .map(|c| c.iter().filter_map(|n| n.as_str().map(str::to_owned)).collect())
            .unwrap_or_default();
        // A send's refusal names the machine it looked on (`hub/no_session.rs`): `no session
        // NAME on HOST; did you mean: a, b, c`.
        let field = |k: &str| data.and_then(|d| d.get(k)?.as_str()).filter(|v| !v.is_empty());
        if let (Some(host), Some(name)) = (field("host"), field("name")) {
            let tail = if candidates.is_empty() {
                "run `acpmux ls` for its sessions".to_owned()
            } else {
                format!("did you mean: {}", candidates.join(", "))
            };
            return Self::new(
                Code::NoSession,
                "no_session",
                format!("no session {name} on {host}; {tail}"),
            )
            .with_data(serde_json::json!({"reason": "no_session", "session": key,
                "candidates": candidates, "host": host, "name": name}));
        }
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
    if let Some(closed) = e.downcast_ref::<crate::client::TransportClosed>() {
        // Why it closed, as codes (`client::closed_cause`): a panic stays told apart from a restart.
        let mut data = serde_json::json!({"cause": closed.cause});
        if let Some(panic) = &closed.panic {
            data["panic"] = panic.clone();
        }
        return AppError::new(Code::Runtime, "daemon_closed", msg).retryable().with_data(data);
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
mod typed_error_tests;
