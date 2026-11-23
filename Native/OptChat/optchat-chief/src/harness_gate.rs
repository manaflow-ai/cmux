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
    /// A harness on an acpmux peer (a cloud subagent): its own profile there,
    /// not checked against this daemon's catalog.
    pub fn peer(harness: &str) -> Admitted {
        Admitted {
            requested: harness.to_owned(),
            profile: harness.to_owned(),
            kind: "peer".to_owned(),
            argv0: String::new(),
            family: crate::acpmux::Family::from_name(harness.split('-').next().unwrap_or(harness)),
        }
    }

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
    refuse_chief_harness(answer, requested)?;
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
    refuse_chief_harness(answer, profile)?;
    cmux_chief::policy::harness::admit_profile(answer, profile).map(|a| admitted(profile, a))
}

/// Peer catalogs deliberately omit argv/env. Admit their reported adapter
/// kind and family, retaining an exact profile for launch. Local admission
/// still checks the command behind reserved route names.
pub fn admit_peer(answer: &Value, requested: &str) -> Result<Admitted, String> {
    let profiles = answer["harnesses"]
        .as_object()
        .ok_or_else(|| "peer did not report its harnesses".to_owned())?;
    // An unredacted catalog can prove a reserved route's command. A
    // redacted one can only admit an exact name: kind/family alone cannot
    // distinguish the person's direct login from the team's paid route.
    if cmux_chief::policy::harness::is_route(requested)
        && profiles.values().any(|row| row["argv"].is_array())
    {
        return admit(answer, requested);
    }
    let profile = requested;
    if !profiles.contains_key(profile) {
        return Err(format!(
            "peer has no harness named {requested}; name an available profile explicitly"
        ));
    }
    if cmux_chief::policy::harness::is_route(requested) && profiles[profile]["kind"] != CLAUDE_STDIO
    {
        return Err(format!(
            "peer's {requested} is not acpmux's {CLAUDE_STDIO} adapter"
        ));
    }
    refuse_chief_harness(answer, profile)?;
    if let Some(why) = profiles[profile]
        .get("unavailable")
        .filter(|v| !v.is_null() && **v != false)
    {
        return Err(format!("peer's {profile} is unavailable: {why}"));
    }
    let mut admitted = admit_profile(answer, profile)?;
    if admitted.kind == CLAUDE_STDIO {
        admitted.family = Family::Claude;
    }
    admitted.requested = requested.into();
    Ok(admitted)
}

/// acpmux's family of its built-in Chief harness (`cmux-tui chief acp`,
/// acpmux `config::CHIEF_FAMILY`).
pub const CHIEF_HARNESS_FAMILY: &str = "chief";

/// Whether acpmux's profile `name` is the Chief harness: the person's chat
/// with a Chief, offered in the agent chat's picker.
pub fn is_chief_harness(answer: &Value, name: &str) -> bool {
    answer
        .get("harnesses")
        .and_then(|h| h.get(name))
        .and_then(|p| p.get("family"))
        .and_then(Value::as_str)
        == Some(CHIEF_HARNESS_FAMILY)
}

/// A Chief never runs a turn, compactor, prewarm or subagent on the Chief
/// harness: each prompt would be a message from the person in its own
/// conversation, which wakes it again without end.
fn refuse_chief_harness(answer: &Value, name: &str) -> Result<(), String> {
    if is_chief_harness(answer, name) {
        return Err(format!(
            "{name} is the Chief harness (the person's chat with a Chief); a Chief's own turns and agents cannot run on it"
        ));
    }
    Ok(())
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

/// The text the Chief gives for a refused turn: plain sentences a person can act on, never the
/// parts it is built from (first-run findings row 1: a fresh Mac's first reply named acpmux,
/// claude-stdio, the CodeRouter CLI and `sr claude proxy`). `reason` stays in the host log and the
/// trace's `harness.refused` (``trace_refusal``), where the person debugging it reads it. It starts
/// with `refused: `, then what is wrong, then (after the first `. `) what to do; the chat posts it
/// through ``refused_reply``.
pub fn refusal(reason: &str) -> String {
    let lower = reason.to_ascii_lowercase();
    // The agent the refused harness runs: Codex, else Claude Code for the Claude routes.
    let agent = if lower.contains("codex") {
        Some("Codex")
    } else if lower.contains("claude") {
        Some("Claude Code")
    } else {
        None
    };
    let missing = lower.contains("has no harness named") || lower.contains("acpmux has none");
    let (what, fix) = match (agent, missing) {
        (Some(agent), true) => (
            format!("Chief answers through {agent}, which is not on this Mac yet."),
            format!("Install {agent} from the Set Up card above, then send again."),
        ),
        (Some(agent), false) => (
            format!("Chief can't run {agent} on this Mac right now."),
            format!("Check {agent} in Set Up cmux… (command palette), then send again."),
        ),
        (None, _) => (
            "Chief couldn't start this reply.".to_owned(),
            "Send again; if it keeps happening, check your agents in Set Up cmux… (command palette)."
                .to_owned(),
        ),
    };
    format!("refused: {what} {fix}")
}

/// What a refused turn posts in the chat (first-run findings row 8: the same tall refusal on every
/// turn made the chat look stuck). `error` is ``refusal``'s text; `asked` is the person's message the
/// turn answers (quoted by its start); `in_row` counts refused turns in a row, from 1. The first
/// names the message and says what is wrong and what to do; a repeat is shorter, says how many in a
/// row, and keeps only what to do. No two turns in a row post the same text.
pub fn refused_reply(error: &str, asked: Option<&str>, in_row: u32) -> String {
    let body = error.strip_prefix("refused: ").unwrap_or(error).trim();
    let (what, fix) = body
        .split_once(". ")
        .map_or((body.to_owned(), String::new()), |(what, fix)| {
            (format!("{what}."), fix.to_owned())
        });
    let quoted = asked.map(quote).filter(|q| !q.is_empty());
    let text = match (in_row, quoted) {
        (0 | 1, Some(q)) => format!("Can't answer “{q}” yet. {what} {fix}"),
        (0 | 1, None) => format!("Can't answer yet. {what} {fix}"),
        (n, Some(q)) => format!("Still can't answer “{q}” ({n} in a row). {fix}"),
        (n, None) => format!("Still can't answer ({n} in a row). {fix}"),
    };
    text.trim().to_owned()
}

/// The start of a person's message for a refused reply: its first line, at most 32 characters.
fn quote(text: &str) -> String {
    const MAX: usize = 32;
    let line = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    if line.chars().count() <= MAX {
        return line.to_owned();
    }
    let cut: String = line.chars().take(MAX - 1).collect();
    format!("{}…", cut.trim_end())
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

#[cfg(test)]
mod refusal_text_tests {
    use super::refusal;

    /// Words a person must never see in Chief's reply: the parts it is built from.
    const INTERNAL: [&str; 9] = [
        "acpmux",
        "claude-stdio",
        "CodeRouter",
        "coderouter",
        "`sr ",
        "claude-sr",
        "claude-cr",
        "adapter",
        "harness",
    ];

    fn plain(shown: &str) {
        assert!(shown.starts_with("refused: "), "{shown}");
        for word in INTERNAL {
            assert!(!shown.contains(word), "{word:?} in {shown}");
        }
    }

    /// A fresh Mac with no Claude Code (first-run findings row 1): Chief's first reply named
    /// acpmux, claude-stdio, the CodeRouter CLI and `sr claude proxy`. It says what is missing
    /// and where to fix it, in plain words.
    #[test]
    fn a_mac_without_claude_code_gets_a_plain_install_line() {
        let shown = refusal(
            "the Chief runs Claude only through acpmux's own Claude Code adapter (kind claude-stdio), and claude asks for one running `claude`; acpmux has none: acpmux has no harness named claude",
        );
        plain(&shown);
        assert!(shown.contains("Claude Code"), "{shown}");
        assert!(shown.contains("Install"), "{shown}");
        assert!(shown.contains("Set Up"), "{shown}");
    }

    /// Every other refusal is plain too: an unavailable route, a Codex Chief with no Codex, a
    /// permission mode that did not apply.
    #[test]
    fn every_other_refusal_names_no_internal_part() {
        for (reason, agent) in [
            (
                "acpmux's claude-cr is unavailable: `cr team-route --version` failed: unknown command",
                "Claude Code",
            ),
            ("acpmux has no harness named codex", "Codex"),
            (
                "the turn's permission mode default did not apply: no such mode",
                "",
            ),
            ("acpmux did not say what its harnesses are (timed out)", ""),
        ] {
            let shown = refusal(reason);
            plain(&shown);
            assert!(shown.contains(agent), "{agent} in {shown}");
        }
    }

    /// First-run findings row 8 ("chat looks stuck"): every refused turn posted the same tall text,
    /// so in a small window the new reply looked exactly like the old one and the person's message
    /// above it was out of view. Each reply now names the message it answers, stays short, and a
    /// repeat says how many in a row: no two turns in a row post the same text.
    #[test]
    fn each_refused_turn_posts_a_short_reply_of_its_own() {
        use super::refused_reply;
        let error = refusal(
            "the Chief runs Claude only through acpmux's own Claude Code adapter (kind claude-stdio); acpmux has none: acpmux has no harness named claude",
        );
        let first = refused_reply(&error, Some("hello?"), 1);
        let second = refused_reply(&error, Some("hello?"), 2);
        let third = refused_reply(&error, Some("are you there"), 3);
        for shown in [&first, &second, &third] {
            assert!(!shown.starts_with('('), "no raw wrapper: {shown}");
            assert!(!shown.contains("refused"), "{shown}");
            for word in INTERNAL {
                assert!(!shown.contains(word), "{word:?} in {shown}");
            }
            assert!(shown.contains("Install Claude Code"), "{shown}");
            assert!(shown.chars().count() <= 200, "short: {shown}");
        }
        assert!(first.contains("“hello?”"), "{first}");
        assert!(third.contains("“are you there”"), "{third}");
        assert_ne!(first, second);
        assert_ne!(second, third);
        assert!(second.contains('2'), "{second}");
        assert!(
            second.chars().count() < first.chars().count(),
            "a repeat is shorter: {second}"
        );
        // A long or multi-line message is quoted by its start only.
        let long = refused_reply(
            &error,
            Some(&format!("{}\nsecond line", "x".repeat(300))),
            1,
        );
        assert!(
            long.chars().count() <= 200 && !long.contains('\n'),
            "{long}"
        );
        // No message to quote (a wake turn): still plain and still per count.
        assert_ne!(
            refused_reply(&error, None, 1),
            refused_reply(&error, None, 2)
        );
    }
}
