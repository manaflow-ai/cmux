//! A terminal chat's failed turn says what went wrong in plain words, as the GUI chat's does
//! (`webviews/.../failureCopy.ts`, cmux#41975, #45314; the credential split of e878064d0621 and
//! 65f286b81d6a). Leo, 2026-11-24: "in terminals and guis alike perhaps terminal simply needs to
//! also have the fixes and enhancements".
//!
//! The TUI drew a harness's raw text alone ("API Error: 401 {\"type\":\"authentication_error\"…}").
//! The error card now leads with the GUI's sentence for the failure's kind and keeps the raw text
//! under it, dimmed. A refused API key and an expired sign-in read differently: a new key fixes
//! one, a sign-in the other. A message no rule knows keeps its own words alone.

use regex::Regex;
use std::sync::LazyLock;

/// Why a turn failed, as the person can act on it. The GUI's `FailureKind`, less its cmux
/// account, Cloud and trust kinds, which only the GUI's routes produce.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    DiskFull,
    ContextFull,
    AccountDisabled,
    UsageLimit,
    NoCredit,
    RateLimited,
    InvalidKey,
    SignedOut,
    Auth,
    Tailscale,
    Unreachable,
    AgentExited,
    SpawnFailed,
}

/// One case-insensitive rule. A pattern that fails to compile matches nothing (the tests compile
/// every one), so a bad rule costs its sentence, never the chat.
struct Rule(LazyLock<Option<Regex>>);

impl Rule {
    fn is_match(&self, message: &str) -> bool {
        self.0.as_ref().is_some_and(|r| r.is_match(message))
    }

    fn group(&self, message: &str) -> Option<String> {
        Some(self.0.as_ref()?.captures(message)?.get(1)?.as_str().to_owned())
    }
}

macro_rules! rule {
    ($name:ident, $pattern:expr) => {
        static $name: Rule = Rule(LazyLock::new(|| Regex::new(concat!("(?i)", $pattern)).ok()));
    };
}

// The GUI's patterns (failureCopy.ts), word for word where the regex crate allows.
rule!(
    DISK_FULL,
    r"ENOSPC|no space left on device|disk (?:is )?full|out of disk space|disk quota exceeded|EDQUOT"
);
rule!(
    CONTEXT_FULL,
    r"prompt is too long|input is too long|context[ _-]?length[ _-]?exceeded|maximum context length|exceeds? (?:the )?(?:model's )?(?:maximum )?context(?: window| length| limit)?|context (?:window|limit) (?:is )?(?:full|exceeded)"
);
rule!(
    ACCOUNT_DISABLED,
    r"\b(?:organization|account) (?:has been|is|was) (?:disabled|suspended|banned|deactivated)\b"
);
rule!(
    USAGE_LIMIT,
    r"hit your (?:(?:[\w-]+ ){0,2}(?:usage|weekly|session|daily|monthly|5-hour|five-hour|opus|sonnet|fable) )?limit\b|(?:usage|weekly|session) limit reached|reached your (?:weekly|session|usage) limit|out of extra usage"
);
rule!(
    NO_CREDIT,
    r"credit balance (?:is )?too low|billing[ _-]hard[ _-]limit|exceeded your current quota|\binsufficient credits?\b|payment required"
);
rule!(
    RATE,
    r"\b(?:429|529)\b|rate.?limit|too many requests|overloaded|at capacity|no non-exhausted|usage limit|quota|\b503\b|service unavailable"
);
rule!(
    INVALID_KEY,
    r"invalid[ _-]?(?:x-)?api[ _-]?key|incorrect api key|api key (?:is )?(?:missing|not set|not found|invalid)|no api key|(?:ANTHROPIC|OPENAI)_API_KEY|api[ _-]?key (?:has |is )?(?:expired|revoked)|expired api[ _-]?key|api_key_expired"
);
rule!(
    SUBSCRIPTION,
    r"not logged in|login required|please (?:run )?/login|(?:claude|codex) (?:auth )?login|oauth token (?:has )?expired|session (?:has )?expired|refresh token|invalid_grant|invalid_rapt|sign(?:ed)? ?in again"
);
rule!(AUTH, r"\b40[13]\b|unauthori[sz]ed|forbidden|authenticat|\boauth\b");
rule!(STATUS, r"\b(40[13])\b");
rule!(TAILSCALE, r"tailscale|tailnet|\.ts\.net\b");
rule!(TAILNET_DOWN, r"not connected|logged out|needs login|is (?:down|stopped|offline)|no route");
rule!(
    UNREACHABLE,
    r"ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|ECONNRESET|EHOSTUNREACH|fetch failed|socket hang up|connection (?:refused|reset|closed|error)|could not (?:connect|resolve)|network (?:error|is unreachable)|\bunreachable\b|timed out"
);
rule!(
    DROPPED,
    r"stream disconnected|error sending request|connection (?:aborted|lost)|upstream connect error|premature close|other side closed|gateway timeout"
);
rule!(
    AGENT_EXITED,
    r"agent process (?:closed|exited|died|ended)|(?:agent|process) exited (?:unexpectedly|with)|exited with (?:code|status|signal)|terminated by signal|\bSIG(?:KILL|TERM|SEGV|ABRT|BUS)\b|broken pipe|\bEPIPE\b"
);
rule!(
    SPAWN_FAILED,
    r"failed to (?:spawn|start|launch)|could not (?:spawn|start|launch)|\bspawn\b.*\bENOENT\b|command not found"
);

/// The kind `message` names, or None when no rule knows it (its own words then stand alone).
pub(crate) fn kind(message: &str) -> Option<Kind> {
    let m = message;
    // A full disk breaks writes, sockets and the agent alike, so it wins over what it broke.
    if DISK_FULL.is_match(m) {
        return Some(Kind::DiskFull);
    }
    if CONTEXT_FULL.is_match(m) {
        return Some(Kind::ContextFull);
    }
    if ACCOUNT_DISABLED.is_match(m) {
        return Some(Kind::AccountDisabled);
    }
    if USAGE_LIMIT.is_match(m) {
        return Some(Kind::UsageLimit);
    }
    // OpenAI sends no credit as a 429: waiting does not help, so before the rate limit.
    if NO_CREDIT.is_match(m) {
        return Some(Kind::NoCredit);
    }
    if RATE.is_match(m) {
        return Some(Kind::RateLimited);
    }
    // A key the provider refused or expired: a new key fixes it, a sign-in does not.
    if INVALID_KEY.is_match(m) {
        return Some(Kind::InvalidKey);
    }
    if SUBSCRIPTION.is_match(m) {
        return Some(Kind::SignedOut);
    }
    let names_auth = AUTH.is_match(m);
    if TAILSCALE.is_match(m) && TAILNET_DOWN.is_match(m) && !names_auth {
        return Some(Kind::Tailscale);
    }
    if names_auth {
        return Some(Kind::Auth);
    }
    if UNREACHABLE.is_match(m) || DROPPED.is_match(m) {
        return Some(Kind::Unreachable);
    }
    if AGENT_EXITED.is_match(m) {
        return Some(Kind::AgentExited);
    }
    if SPAWN_FAILED.is_match(m) {
        return Some(Kind::SpawnFailed);
    }
    None
}

/// The card's lead sentence for `message`: the GUI's English copy (Localizable.xcstrings
/// `turn.failure.*`), or None when no rule knows the message. `harness` is the agent's name.
pub(crate) fn sentence(message: &str, harness: &str) -> Option<String> {
    let h = harness;
    Some(match kind(message)? {
        Kind::DiskFull => {
            format!("The disk is full, so {h} couldn’t keep going. Free up some space, then retry.")
        }
        Kind::ContextFull => {
            format!("This chat is too long for {h}’s context window. Compact it, then retry.")
        }
        Kind::AccountDisabled => format!(
            "{h}'s provider turned this account off (disabled or suspended), so no message can run on it. Use another agent, or sign in with another account."
        ),
        Kind::UsageLimit => format!(
            "{h}'s account hit its usage limit; every message fails the same way until it resets. Use another agent to keep going now, or sign in with another account."
        ),
        Kind::NoCredit => format!(
            "{h} was refused: this chat's API key account is out of credit. Add credit and retry, or switch model."
        ),
        Kind::RateLimited => format!(
            "{h} is rate limited or out of capacity. Try again in a moment, or switch model."
        ),
        Kind::InvalidKey => format!("{h} has no valid API key. Check the key its profile uses."),
        Kind::SignedOut => format!("{h} is signed out or its sign-in expired."),
        Kind::Auth => {
            let status = STATUS.group(message).unwrap_or_else(|| "401".to_owned());
            format!("The provider refused {h}’s credentials ({status}).")
        }
        Kind::Tailscale => format!(
            "{h} couldn’t reach its machine over Tailscale. Check that Tailscale is connected, then retry."
        ),
        Kind::Unreachable => format!("{h} could not reach its server."),
        Kind::AgentExited => format!("{h} quit before it finished this turn."),
        Kind::SpawnFailed => format!("{h} couldn’t start."),
    })
}

/// A sentence starts with the agent's name, so "the agent" reads "The agent" there.
pub(crate) fn sentence_for(message: &str, harness: Option<&str>) -> Option<String> {
    let name = harness.map(crate::agent_names::display_name);
    let text = sentence(message, name.as_deref().unwrap_or("the agent"))?;
    let mut chars = text.chars();
    Some(match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => text,
    })
}

#[cfg(test)]
#[path = "failure_copy_tests.rs"]
mod tests;
