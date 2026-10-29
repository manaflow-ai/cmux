//! `_acpmux/complete` (hq#1957): one cheap completion through the user's own
//! harness login, for naming chats and workspaces. No chat session, no
//! tools, no MCP, no hooks, no session file, no chat-list entry.
//!
//! It is the live-model probe's shape (`crate::live_models`), not a chat:
//! the harness CLI runs once, headless, with the harness's login and profile
//! env and its bound route (`hub/complete.rs`), in one fixed empty cwd
//! ([`places`]), and its answer is read from stdout (Codex:
//! `--output-last-message`).
//!
//! - [`recipes`]: which harnesses have a headless recipe and their exact argv.
//! - [`codex_config`]: the user's own Codex model provider, passed back.
//! - [`model_pick`]: the harness's small model when the caller names none.
//! - [`run`]: the child under a deadline, its whole process group killed on
//!   timeout, stdout capped.
//!
//! The unix socket only ([`allowed`], default deny). The method is answered
//! at the connection's front door (`server/chats.rs`), before the request
//! path's `remote_guard`, so `Hub::complete` checking [`allowed`] first is
//! the one gate: the caller picks the prompt this machine sends with the
//! user's own account. Relay analysis
//! (skills/cmux-socket-policy/references/remote-relay-authorization.md): it
//! runs a local process (a harness CLI, never a caller's command) and spends
//! the local account's quota, so no relay or remote origin may call it:
//! Web (a remote browser), Peer (a peer daemon, also forwarding for its own
//! clients) and LocalApp (the agent pane, which never makes this machine
//! spawn a process; the app's own code asks over the unix socket) are
//! refused. It takes no command-bearing params and names no workspace,
//! surface or session object; its answer holds only the model's text.
//!
//! The prompt is never logged; the daemon logs the harness, the model and
//! how long it took.

pub mod codex_config;
pub mod model_pick;
pub mod places;
pub mod recipes;
pub mod run;

use crate::no_panic::JsonExt;
use crate::no_panic::StrExt;
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::time::Duration;

/// The longest prompt, in UTF-8 bytes.
pub const MAX_PROMPT_BYTES: usize = 4096;
pub const DEFAULT_MAX_TOKENS: u32 = 16;
pub const MAX_MAX_TOKENS: u32 = 256;
pub const DEFAULT_TIMEOUT_MS: u32 = 20_000;
pub const MAX_TIMEOUT_MS: u32 = 60_000;
/// The most of the CLI's stdout (or Codex's last-message file) read.
pub const OUTPUT_CAP: usize = 64 * 1024;
/// The most of its stderr read, only to tell a sign-in failure.
pub const STDERR_CAP: usize = 8 * 1024;
/// Bytes per token when the answer is cut to `maxTokens`: the CLIs take no
/// output limit, so the daemon cuts the answer to about that many tokens.
pub const BYTES_PER_TOKEN: usize = 4;

/// Whether a connection from `origin` may call `_acpmux/complete`: the unix
/// socket only.
pub fn allowed(origin: crate::server::Origin) -> bool {
    use crate::server::Origin;
    match origin {
        Origin::Local => true,
        Origin::Web | Origin::LocalApp | Origin::Peer => false,
    }
}

/// One `_acpmux/complete` request, checked.
#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    pub prompt: String,
    /// None: the daemon's default harness.
    pub harness: Option<String>,
    /// None: the harness's small model (`model_pick`).
    pub model: Option<String>,
    pub max_tokens: u32,
    pub timeout: Duration,
}

impl Request {
    /// Reads and checks `{prompt, harness?, model?, maxTokens?, timeoutMs?}`.
    pub fn parse(params: &Value) -> Result<Self, CompleteError> {
        let prompt = params
            .get("prompt")
            .and_then(Value::as_str)
            .ok_or_else(|| CompleteError::InvalidParams("prompt (a string) is required".into()))?;
        if prompt.trim().is_empty() {
            return Err(CompleteError::InvalidParams("prompt is empty".into()));
        }
        if prompt.len() > MAX_PROMPT_BYTES {
            return Err(CompleteError::PromptTooLarge { bytes: prompt.len() });
        }
        let text = |key: &str| -> Result<Option<String>, CompleteError> {
            match params.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
                Some(Value::String(s)) => Ok(Some(s.trim().to_owned())),
                Some(_) => Err(CompleteError::InvalidParams(format!("{key} must be a string"))),
            }
        };
        let number = |key: &str, default: u32, max: u32| -> Result<u32, CompleteError> {
            match params.get(key) {
                None | Some(Value::Null) => Ok(default),
                Some(v) => v
                    .as_u64()
                    .and_then(|n| u32::try_from(n).ok())
                    .filter(|n| (1..=max).contains(n))
                    .ok_or_else(|| {
                        CompleteError::InvalidParams(format!(
                            "{key} must be a number from 1 to {max}"
                        ))
                    }),
            }
        };
        // A model id, never a flag, whitespace or a control character;
        // `default` is no model (the small model is picked and reported).
        let model = match params.get("model") {
            None | Some(Value::Null) => None,
            Some(Value::String(m)) if m.is_empty() || m == "default" => None,
            Some(Value::String(m))
                if m.starts_with('-') || m.chars().any(|c| c.is_whitespace() || c.is_control()) =>
            {
                return Err(CompleteError::InvalidParams(
                    "model must be a model id: no leading '-', whitespace or control characters"
                        .into(),
                ));
            }
            Some(Value::String(m)) => Some(m.clone()),
            Some(_) => return Err(CompleteError::InvalidParams("model must be a string".into())),
        };
        Ok(Self {
            prompt: prompt.to_owned(),
            harness: text("harness")?,
            model,
            max_tokens: number("maxTokens", DEFAULT_MAX_TOKENS, MAX_MAX_TOKENS)?,
            timeout: Duration::from_millis(u64::from(number(
                "timeoutMs",
                DEFAULT_TIMEOUT_MS,
                MAX_TIMEOUT_MS,
            )?)),
        })
    }
}

/// Why a completion did not answer. Each carries a `data.reason`.
#[derive(Debug, Clone, PartialEq)]
pub enum CompleteError {
    InvalidParams(String),
    PromptTooLarge {
        bytes: usize,
    },
    /// Asked over a connection that is not the local unix socket.
    LocalOnly,
    /// No profile by that name (or no default harness).
    UnknownHarness(String),
    /// The harness has no headless recipe (Gemini, a terminal harness, an ACP adapter).
    Unsupported {
        harness: String,
        why: String,
    },
    /// The recipe's program is not installed.
    NotInstalled {
        harness: String,
        program: String,
    },
    SignedOut {
        harness: String,
    },
    Timeout {
        harness: String,
        ms: u64,
    },
    EmptyOutput {
        harness: String,
    },
    /// The CLI failed for another reason (its exit status, a spawn error).
    Failed {
        harness: String,
        detail: String,
    },
}

impl CompleteError {
    /// The `data.reason` id.
    pub fn reason(&self) -> &'static str {
        match self {
            Self::InvalidParams(_) => "complete.invalid_params",
            Self::PromptTooLarge { .. } => "complete.prompt_too_large",
            Self::LocalOnly => "complete.local_only",
            Self::UnknownHarness(_) => "complete.unknown_harness",
            Self::Unsupported { .. } => "complete.unsupported_harness",
            Self::NotInstalled { .. } => "complete.not_installed",
            Self::SignedOut { .. } => "complete.signed_out",
            Self::Timeout { .. } => "complete.timeout",
            Self::EmptyOutput { .. } => "complete.empty_output",
            Self::Failed { .. } => "complete.failed",
        }
    }

    fn message(&self) -> String {
        match self {
            Self::InvalidParams(m) => m.clone(),
            Self::PromptTooLarge { bytes } => {
                format!("prompt is {bytes} bytes; the most is {MAX_PROMPT_BYTES}")
            }
            Self::LocalOnly => {
                "_acpmux/complete is accepted only over the local unix socket".into()
            }
            Self::UnknownHarness(h) => format!("no harness named {h:?}"),
            Self::Unsupported { harness, why } => {
                format!("{harness} cannot answer a one-shot completion: {why}")
            }
            Self::NotInstalled { harness, program } => {
                format!("{harness}: {program} is not installed")
            }
            Self::SignedOut { harness } => format!("{harness} is not signed in"),
            Self::Timeout { harness, ms } => format!("{harness} did not answer within {ms} ms"),
            Self::EmptyOutput { harness } => format!("{harness} answered with no text"),
            Self::Failed { harness, detail } => format!("{harness} failed: {detail}"),
        }
    }

    fn code(&self) -> i64 {
        match self {
            Self::InvalidParams(_) | Self::PromptTooLarge { .. } | Self::LocalOnly => -32602,
            Self::UnknownHarness(_) => -32002,
            _ => -32000,
        }
    }
}

impl From<CompleteError> for RpcError {
    fn from(e: CompleteError) -> Self {
        let mut data = json!({"reason": e.reason()});
        match &e {
            CompleteError::UnknownHarness(h) => {
                data.set("harness", json!(h));
            }
            CompleteError::Unsupported { harness, .. }
            | CompleteError::NotInstalled { harness, .. }
            | CompleteError::SignedOut { harness }
            | CompleteError::EmptyOutput { harness }
            | CompleteError::Failed { harness, .. } => {
                data.set("harness", json!(harness));
            }
            CompleteError::Timeout { harness, ms } => {
                data.set("harness", json!(harness));
                data.set("timeoutMs", json!(ms));
            }
            CompleteError::InvalidParams(_)
            | CompleteError::PromptTooLarge { .. }
            | CompleteError::LocalOnly => {}
        }
        if let CompleteError::PromptTooLarge { .. } = &e {
            data.set("maxBytes", json!(MAX_PROMPT_BYTES));
        }
        RpcError::new(e.code(), e.message()).with_data(data)
    }
}

/// The answer from a finished CLI: `answer` is its stdout, or Codex's
/// last-message file. Trimmed, cut to about `max_tokens` tokens on a
/// character boundary. A failed run whose stderr names sign-in is
/// [`CompleteError::SignedOut`]; stdout (the model's text) never is.
pub fn finish(
    harness: &str,
    out: &run::Output,
    answer: &[u8],
    max_tokens: u32,
) -> Result<String, CompleteError> {
    if !out.success {
        // The CLI's own error, never the model's text on stdout.
        if crate::harness_health::names_sign_in(&String::from_utf8_lossy(&out.stderr)) {
            return Err(CompleteError::SignedOut { harness: harness.to_owned() });
        }
        let stderr = String::from_utf8_lossy(&out.stderr);
        let last = stderr.lines().rev().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
        let detail = match out.code {
            Some(code) => format!("exit status {code}"),
            None => "killed by a signal".to_owned(),
        };
        let detail = if last.is_empty() { detail } else { format!("{detail}: {}", cut(last, 300)) };
        return Err(CompleteError::Failed { harness: harness.to_owned(), detail });
    }
    let text = String::from_utf8_lossy(answer);
    let text = cut(text.trim(), max_tokens as usize * BYTES_PER_TOKEN).trim();
    if text.is_empty() {
        return Err(CompleteError::EmptyOutput { harness: harness.to_owned() });
    }
    Ok(text.to_owned())
}

/// `s` cut to at most `max` bytes on a character boundary.
pub fn cut(s: &str, max: usize) -> &str {
    s.head(max)
}

#[cfg(test)]
mod tests;
