//! Which acpmux harness may answer for the Chief (Lawrence, 2026-10-05:
//! "we have our own version that uses claude code cli stdio, ensure only
//! that one is being used").
//!
//! A Claude harness is admitted only when acpmux reports it as kind
//! `claude-stdio`: acpmux's own Claude Code adapter (`claude_stdio`), which
//! drives `claude -p --input-format stream-json`. An external ACP adapter
//! (`claude-acp`, kind `acp`) is refused, whatever its profile is named. An
//! acpmux can carry one under the reserved names: `~/.acpx` entries are
//! imported as kind `acp`, and a failing `sr claude proxy` launcher is
//! replaced by a copy of the `claude` profile.
//!
//! The reserved names are routes, not profile names: `claude-sr` asks for a
//! `claude-stdio` profile whose command is `sr claude proxy` (the team
//! subrouter pool), `claude` for one whose command is `claude` (the direct
//! login). The profile is found by kind and command in `_acpmux/harnesses`,
//! so a user profile named `claude` that runs an ACP adapter is never
//! picked. Any other harness keeps its name; a Claude-family one must still
//! be kind `claude-stdio`. Codex and the other families are not Claude and
//! are admitted as acpmux reports them.

use serde::Serialize;
use serde_json::Value;

use crate::acpmux::{AgentPort, Family, harness_family};
use crate::trace::Trace;

/// acpmux's kind for its own Claude Code adapter.
pub const CLAUDE_STDIO: &str = "claude-stdio";

/// A harness the gate admitted: the acpmux profile a session asks for, and
/// what acpmux says it runs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Admitted {
    /// The name the Chief was configured with (`claude-sr`, `codex`, ...).
    pub requested: String,
    /// The acpmux profile that matched: the session's `harness`.
    pub profile: String,
    /// acpmux's kind for it (`claude-stdio`, `acp`).
    pub kind: String,
    /// The first word of its command (the executable path).
    pub argv0: String,
    #[serde(skip)]
    pub family: Family,
}

impl Admitted {
    /// `claude-sr -> claude-sr (claude-stdio, /Users/me/bin/sr)`.
    pub fn describe(&self) -> String {
        let name = if self.requested == self.profile {
            self.profile.clone()
        } else {
            format!("{} -> {}", self.requested, self.profile)
        };
        format!("{name} ({}, {})", self.kind, self.argv0)
    }
}

/// The team subrouter's addresses (cmux_chief::policy::harness).
pub use cmux_chief::policy::harness::TEAM_SUBROUTER_URLS;

/// The profile `requested` runs on, from an `_acpmux/harnesses` answer, or
/// why the Chief refuses it.
pub fn admit(answer: &Value, requested: &str) -> Result<Admitted, String> {
    // A profile asked for by name (a configured `claude-cr`, say) whose
    // launcher acpmux marked unavailable is refused here, as a route is,
    // instead of failing at the first turn.
    if !cmux_chief::policy::harness::is_route(requested)
        && let Some(why) = answer
            .get("harnesses")
            .and_then(|h| h.get(requested))
            .and_then(|p| p.get("unavailable"))
            .and_then(Value::as_str)
    {
        return Err(format!("acpmux's {requested} is unavailable: {why}"));
    }
    cmux_chief::policy::harness::admit(answer, requested).map(|a| admitted(requested, a))
}

/// A profile by its exact name (a session's harness after acpmux resolved
/// it): refused when it is Claude and not kind `claude-stdio`.
pub fn admit_profile(answer: &Value, profile: &str) -> Result<Admitted, String> {
    cmux_chief::policy::harness::admit_profile(answer, profile).map(|a| admitted(profile, a))
}

/// The shared rule's admission (cmux_chief::policy::harness, the corpus's
/// `policy` cases) as this host's `Admitted`.
fn admitted(requested: &str, a: cmux_chief::policy::harness::Admission) -> Admitted {
    Admitted {
        requested: requested.to_owned(),
        family: Family::from_name(&a.family),
        profile: a.profile,
        kind: a.kind,
        argv0: a.argv0,
    }
}

/// The text the Chief posts for a refused turn.
pub fn refusal(reason: &str) -> String {
    format!(
        "refused: {reason}. Fix the acpmux harness (`acpmux daemon harnesses` lists them; the CodeRouter CLI must have the configured route for claude-cr, `sr claude proxy --version` must succeed for claude-sr) and send the message again."
    )
}

/// Admits `requested` against the daemon's current harnesses (asked at each
/// session, so a daemon restarted with other profiles is seen at once).
pub fn admit_live(agents: &dyn AgentPort, requested: &str) -> Result<Admitted, String> {
    let answer = agents
        .harness_catalog()
        .map_err(|e| format!("acpmux did not say what its harnesses are ({e})"))?;
    admit(&answer, requested)
}

/// The harness acpmux actually runs session `id` on: `admitted` when it is
/// the one asked for (or acpmux does not say), else that other profile,
/// refused unless it too is allowed (a family preference or a fallback can
/// move a session onto another profile).
pub fn session_harness(
    agents: &dyn AgentPort,
    id: &str,
    admitted: &Admitted,
) -> Result<Admitted, String> {
    let actual = match agents.session(id) {
        Ok(Some(summary)) if !summary.harness.is_empty() => summary.harness,
        Ok(_) => return Ok(admitted.clone()),
        Err(e) => return Err(format!("acpmux did not say which harness runs {id} ({e})")),
    };
    if actual == admitted.profile {
        return Ok(admitted.clone());
    }
    let answer = agents
        .harness_catalog()
        .map_err(|e| format!("acpmux did not say what its harnesses are ({e})"))?;
    admit_profile(&answer, &actual)
        .map(|mut a| {
            a.requested = admitted.requested.clone();
            a
        })
        .map_err(|e| {
            format!(
                "acpmux runs the session on {actual}, not {}: {e}",
                admitted.profile
            )
        })
}

/// The trace's `harness.refused`: which Chief session (`role`), the harness
/// it asked for, and why.
pub fn trace_refusal(trace: &Trace, role: &str, requested: &str, reason: &str) {
    trace.emit(
        "harness.refused",
        serde_json::json!({"role": role, "harness": requested, "reason": reason}),
    );
}

/// A harness at host start: the family its sessions are laid out for, the
/// profile its presets name, and the admission.
#[derive(Clone, Debug)]
pub struct Plan {
    pub family: Family,
    pub profile: String,
    pub admitted: Result<Admitted, String>,
}

/// Plans `requested` from the start-up answer. A refused harness keeps the
/// host running (each of its sessions is refused in the chat until acpmux
/// has the adapter): a reserved name is laid out as Claude, another name as
/// acpmux reports it, and its presets name it as asked.
pub fn plan(answer: &Value, requested: &str) -> Plan {
    let admitted = admit(answer, requested);
    match &admitted {
        Ok(a) => Plan {
            family: a.family,
            profile: a.profile.clone(),
            admitted,
        },
        Err(_) => Plan {
            family: if cmux_chief::policy::harness::is_route(requested) {
                Family::Claude
            } else {
                harness_family(answer, requested).unwrap_or(Family::Other)
            },
            profile: requested.to_owned(),
            admitted,
        },
    }
}
