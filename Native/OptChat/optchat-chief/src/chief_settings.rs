//! Per-Chief settings, `$MUX_HOME/optchat/settings.json`
//! (`{"cache": {"ttl": "1h"}}`), shown later in the Chief settings
//! sidebar. The host reads the file once at start and owns the value after
//! that: a change goes through the host (`Brain::set_setting`), which writes
//! the file. An edit of the file by hand takes effect at the next host start.
//! No setting makes the Chief ask before it acts (Lawrence, 2026-10-20:
//! "chief should never have to ask for approvals"); the old `remote.*` and
//! `home.ask` keys are ignored when read and dropped at the next write.

use std::path::Path;

use serde_json::{Value, json};

use crate::prompt::CacheTtl;

/// The settings this host knows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChiefSettings {
    /// How long a turn's prompt cache entries live (`5m` or `1h`); None: the
    /// engine's default (1 hour on the Claude Code path, 5 minutes on the
    /// native engine). `OPTCHAT_CACHE_TTL` wins over it.
    pub cache_ttl: Option<CacheTtl>,
    /// Optional coordinator session (`host/session`) for fleet, PR and lane work.
    /// Unset by default; its identity is added to the prompt at host start.
    pub contact: Option<String>,
    /// When a reply in the Chief's DM goes into the thread of the message it
    /// answers (`replies.thread`). Default `auto`.
    pub reply_threads: ReplyThreads,
    /// A subagent's report that names landed commits, pages or preview files
    /// gets a `<show>` block for the Chief to open them in the subagent's
    /// workspace or a new one (`show.afterReport`, crate::show). Default true.
    pub show_after_report: bool,
    /// Each subagent gets a sidebar workspace when it starts
    /// (`subagents.showWorkspaces`). Default false (#26386): subagents run
    /// hidden, reachable from their links in the Chief's replies, and
    /// `control show ID` / `control hide ID` add or close one's workspace.
    pub show_subagent_workspaces: bool,
    /// The trace keeps whole texts (replies, tool arguments) for replaying
    /// real turns (`trace.full`). Default false.
    pub trace_full: bool,
    /// The most words a reply's first send of a turn may have before it is
    /// refused for Chief to cut (`replies.maxWords`, chief_kernel::replies);
    /// 0 turns the gate off. Default 45.
    pub reply_max_words: usize,
    /// Whether the host pauses cloud VMs on its own (`cloud.autoPause`):
    /// a pool VM after `cloud.autoPauseIdleSeconds` with no live subagent, a
    /// subagent's own VM when its run ends, and every idle one when the host
    /// stops. Default false: no auto pause (Leo, 2026-10-30: "we're saying
    /// no auto pausing of the freestyle vms for now"). Pausing by hand is
    /// unchanged.
    pub cloud_auto_pause: bool,
    /// Seconds a cloud VM waits with no live cloud subagent before the host
    /// pauses it, when `cloud.autoPause` is on (`cloud.autoPauseIdleSeconds`,
    /// cloud-subagents-DESIGN.md B4). Default 60.
    pub cloud_auto_pause_idle_secs: u64,
    /// Days a finished subagent's own VM stays paused (for a later tell)
    /// before the host deletes it (`cloud.deleteAfterPausedDays`,
    /// cloud-subagents-DESIGN.md v2).
    pub cloud_delete_after_paused_days: u64,
    /// Whether a message from a trusted agent session (`relay.trustAgents`)
    /// may drive `tell` and `spawn` to the Chief's own subagents. Default
    /// true; false gives every agent session's message the whole ask floor.
    pub trust_agents: bool,
    /// The acpmux sessions whose messages the owner trusts
    /// (`relay.trustedAgents`): exact names or one `*` glob each. Default
    /// [`DEFAULT_TRUSTED_AGENTS`]; the `contact` session is trusted too.
    pub trusted_agents: Vec<String>,
}

/// `replies.thread`: when a Chief reply in its DM is threaded under the user
/// message it answers (a group conversation always threads).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ReplyThreads {
    /// Only when that message is no longer the newest one in the
    /// conversation (a late reply, a subagent's report): a reply right under
    /// its message stays at the top level, as in iMessage.
    #[default]
    Auto,
    /// Every reply that answers a user message.
    Always,
    /// None (the DM before 2026-10-20).
    Never,
}

impl ReplyThreads {
    pub fn parse(value: &str) -> Option<ReplyThreads> {
        match value.trim() {
            "auto" => Some(ReplyThreads::Auto),
            "always" => Some(ReplyThreads::Always),
            "never" => Some(ReplyThreads::Never),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            ReplyThreads::Auto => "auto",
            ReplyThreads::Always => "always",
            ReplyThreads::Never => "never",
        }
    }
}

impl Default for ChiefSettings {
    fn default() -> ChiefSettings {
        ChiefSettings {
            cache_ttl: None,
            contact: None,
            reply_threads: ReplyThreads::Auto,
            show_after_report: true,
            show_subagent_workspaces: false,
            trace_full: false,
            reply_max_words: chief_kernel::replies::REPLY_MAX_WORDS,
            cloud_auto_pause: false,
            cloud_auto_pause_idle_secs: 60,
            cloud_delete_after_paused_days: 7,
            trust_agents: true,
            trusted_agents: default_trusted_agents(),
        }
    }
}

/// The owner's coordinator sessions, by the fleet's naming (`<name>-coord`).
pub const DEFAULT_TRUSTED_AGENTS: [&str; 1] = ["*-coord"];

fn default_trusted_agents() -> Vec<String> {
    DEFAULT_TRUSTED_AGENTS
        .iter()
        .map(|s| (*s).to_owned())
        .collect()
}

/// The key of `ChiefSettings::trust_agents`.
pub const TRUST_AGENTS: &str = "relay.trustAgents";

/// The key of `ChiefSettings::trusted_agents`.
pub const TRUSTED_AGENTS: &str = "relay.trustedAgents";

/// The key of `ChiefSettings::cache_ttl`.
pub const CACHE_TTL: &str = "cache.ttl";

/// The optional coordinator session used for fleet, PR and lane work.
pub const CONTACT: &str = "contact";

/// The key of `ChiefSettings::reply_threads`.
pub const REPLY_THREADS: &str = "replies.thread";

/// The key of `ChiefSettings::show_after_report`.
pub const SHOW_AFTER_REPORT: &str = "show.afterReport";

/// The key of `ChiefSettings::show_subagent_workspaces`.
pub const SHOW_SUBAGENT_WORKSPACES: &str = "subagents.showWorkspaces";

/// The key of `ChiefSettings::reply_max_words`.
pub const REPLY_MAX_WORDS: &str = "replies.maxWords";

/// The key of `ChiefSettings::trace_full`.
pub const TRACE_FULL: &str = "trace.full";

/// The key of `ChiefSettings::cloud_auto_pause`.
pub const CLOUD_AUTO_PAUSE: &str = "cloud.autoPause";

/// The key of `ChiefSettings::cloud_auto_pause_idle_secs`.
pub const CLOUD_AUTO_PAUSE_IDLE_SECONDS: &str = "cloud.autoPauseIdleSeconds";

impl ChiefSettings {
    /// The settings in `path`; a missing or unreadable file is the defaults.
    pub fn load(path: &Path) -> ChiefSettings {
        let value: Value = std::fs::read_to_string(path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null);
        ChiefSettings {
            cache_ttl: value["cache"]["ttl"].as_str().and_then(CacheTtl::parse),
            contact: value[CONTACT]
                .as_str()
                .and_then(|v| parse_contact(v).ok().flatten()),
            reply_threads: value["replies"]["thread"]
                .as_str()
                .and_then(ReplyThreads::parse)
                .unwrap_or_default(),
            show_after_report: value["show"]["afterReport"].as_bool().unwrap_or(true),
            show_subagent_workspaces: value["subagents"]["showWorkspaces"]
                .as_bool()
                .unwrap_or(false),
            trace_full: value["trace"]["full"].as_bool().unwrap_or(false),
            reply_max_words: value["replies"]["maxWords"]
                .as_u64()
                .map(|n| n as usize)
                .unwrap_or(chief_kernel::replies::REPLY_MAX_WORDS),
            cloud_auto_pause: value["cloud"]["autoPause"].as_bool().unwrap_or(false),
            cloud_auto_pause_idle_secs: value["cloud"]["autoPauseIdleSeconds"]
                .as_u64()
                .unwrap_or(60),
            cloud_delete_after_paused_days: value["cloud"]["deleteAfterPausedDays"]
                .as_u64()
                .unwrap_or(7),
            trust_agents: value["relay"]["trustAgents"].as_bool().unwrap_or(true),
            trusted_agents: value["relay"]["trustedAgents"]
                .as_array()
                .map(|names| {
                    names
                        .iter()
                        .filter_map(Value::as_str)
                        .filter_map(clean_agent_pattern)
                        .collect()
                })
                .unwrap_or_else(default_trusted_agents),
        }
    }

    /// Whether a message the acpmux session `name` sent through the owner's
    /// CLI may drive `tell` and `spawn` to the Chief's own subagents: the
    /// setting is on and the name (or, for a peer's `host/name`, its last
    /// part) matches `relay.trustedAgents` or is the `contact` session.
    pub fn trusts_agent(&self, name: &str) -> bool {
        if !self.trust_agents {
            return false;
        }
        let name = name.trim();
        let short = name.rsplit('/').next().unwrap_or(name);
        if short.is_empty() {
            return false;
        }
        let contact = self
            .contact
            .as_deref()
            .and_then(|c| c.split_once('/'))
            .map(|(_, session)| session);
        if contact == Some(short) {
            return true;
        }
        self.trusted_agents
            .iter()
            .any(|p| glob_matches(p, name) || glob_matches(p, short))
    }

    pub fn to_json(&self) -> Value {
        let mut value = json!({});
        if let Some(contact) = &self.contact {
            value[CONTACT] = json!(contact);
        }
        if let Some(ttl) = self.cache_ttl {
            value["cache"] = json!({"ttl": ttl.as_str()});
        }
        value["replies"] =
            json!({"thread": self.reply_threads.as_str(), "maxWords": self.reply_max_words});
        value["show"] = json!({"afterReport": self.show_after_report});
        value["subagents"] = json!({"showWorkspaces": self.show_subagent_workspaces});
        if self.trace_full {
            value["trace"] = json!({"full": true});
        }
        value["cloud"] = json!({
            "autoPause": self.cloud_auto_pause,
            "autoPauseIdleSeconds": self.cloud_auto_pause_idle_secs,
            "deleteAfterPausedDays": self.cloud_delete_after_paused_days,
        });
        value["relay"] = json!({
            "trustAgents": self.trust_agents,
            "trustedAgents": self.trusted_agents,
        });
        value
    }

    /// Writes the settings (0600, through a temporary file and a rename).
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(format!("{:#}\n", self.to_json()).as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&tmp, path)
    }
}

/// The key of `ChiefSettings::cloud_delete_after_paused_days`.
pub const CLOUD_DELETE_AFTER_PAUSED_DAYS: &str = "cloud.deleteAfterPausedDays";

/// A `contact` value is an acpmux session id in `host/session` form.
/// An empty value clears it. Whitespace and additional separators are rejected
/// so the prompt cannot be made to point at an ambiguous session.
pub fn parse_contact(value: &str) -> Result<Option<String>, String> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(None);
    }
    let Some((host, session)) = value.split_once('/') else {
        return Err(format!("{CONTACT}: expected host/session, not {value:?}"));
    };
    if host.is_empty()
        || session.is_empty()
        || session.contains('/')
        || value.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(format!("{CONTACT}: expected host/session, not {value:?}"));
    }
    Ok(Some(value.to_owned()))
}

/// A `cloud.deleteAfterPausedDays` value: whole days, 0 to 365.
pub fn parse_paused_days(value: &str) -> Result<u64, String> {
    value
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|n| *n <= 365)
        .ok_or_else(|| {
            format!("{CLOUD_DELETE_AFTER_PAUSED_DAYS}: whole days 0..365, not {value:?}")
        })
}

/// A `cloud.autoPauseIdleSeconds` value: whole seconds, 0 to 86400.
pub fn parse_idle_secs(value: &str) -> Result<u64, String> {
    value
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|n| *n <= 86_400)
        .ok_or_else(|| {
            format!("{CLOUD_AUTO_PAUSE_IDLE_SECONDS}: whole seconds 0..86400, not {value:?}")
        })
}

/// A cache TTL setting value: `5m` or `1h`.
pub fn parse_ttl(value: &str) -> Result<CacheTtl, String> {
    CacheTtl::parse(value).ok_or_else(|| format!("expected 5m or 1h, not {:?}", value.trim()))
}

/// A `replies.thread` setting value: `auto`, `always` or `never`.
pub fn parse_reply_threads(value: &str) -> Result<ReplyThreads, String> {
    ReplyThreads::parse(value)
        .ok_or_else(|| format!("expected auto, always or never, not {:?}", value.trim()))
}

/// A boolean setting value: `true` or `false`.
pub fn parse_bool(value: &str) -> Result<bool, String> {
    match value.trim() {
        "true" => Ok(true),
        "false" => Ok(false),
        other => Err(format!("expected true or false, not {other:?}")),
    }
}

/// One `relay.trustedAgents` entry: trimmed, with at most one `*` and no
/// whitespace; None for an empty or a bare `*` one (that would trust every
/// agent, which is what turning the guard off is for).
fn clean_agent_pattern(value: &str) -> Option<String> {
    let value = value.trim();
    let ok = !value.is_empty()
        && value != "*"
        && value.matches('*').count() <= 1
        && !value.chars().any(|c| c.is_whitespace() || c.is_control());
    ok.then(|| value.to_owned())
}

/// Whether `name` matches `pattern`: equal, or with its one `*` standing for
/// any run of characters.
fn glob_matches(pattern: &str, name: &str) -> bool {
    match pattern.split_once('*') {
        None => pattern == name,
        Some((head, tail)) => {
            name.len() >= head.len() + tail.len() && name.starts_with(head) && name.ends_with(tail)
        }
    }
}

/// A `relay.trustedAgents` value: session names or `*` globs, separated by
/// commas or spaces; empty clears the list (only the `contact` stays trusted).
pub fn parse_trusted_agents(value: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for part in value.split(|c: char| c == ',' || c.is_whitespace()) {
        if part.is_empty() {
            continue;
        }
        let Some(pattern) = clean_agent_pattern(part) else {
            return Err(format!(
                "{TRUSTED_AGENTS}: {part:?} is not a session name or a pattern with one `*` (a bare `*` is refused: set {TRUST_AGENTS} instead)"
            ));
        };
        if !out.contains(&pattern) {
            out.push(pattern);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod trusted_agent_tests {
    use super::*;

    #[test]
    fn coordinator_sessions_are_trusted_by_default_and_others_are_not() {
        let s = ChiefSettings::default();
        assert!(s.trusts_agent("claude-sr2-coord"));
        assert!(s.trusts_agent("big-red/claude-sr2-coord"));
        assert!(!s.trusts_agent("lane-a"));
        assert!(!s.trusts_agent("coord-lane"));
        assert!(!s.trusts_agent(""));
    }

    #[test]
    fn the_contact_is_trusted_and_the_switch_turns_all_of_it_off() {
        let mut s = ChiefSettings {
            contact: Some("air-blue/lead".into()),
            trusted_agents: Vec::new(),
            ..ChiefSettings::default()
        };
        assert!(s.trusts_agent("lead"));
        assert!(!s.trusts_agent("fleet-coord"));
        s.trust_agents = false;
        assert!(!s.trusts_agent("lead"));
    }

    #[test]
    fn the_list_round_trips_and_refuses_a_bare_star() {
        let list = parse_trusted_agents("ops-coord, lead-*  lead-*").unwrap();
        assert_eq!(list, vec!["ops-coord".to_owned(), "lead-*".to_owned()]);
        assert!(parse_trusted_agents("*").is_err());
        assert!(parse_trusted_agents("a*b*").is_err());
        assert_eq!(parse_trusted_agents("").unwrap(), Vec::<String>::new());
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("settings.json");
        let s = ChiefSettings {
            trust_agents: false,
            trusted_agents: list.clone(),
            ..ChiefSettings::default()
        };
        s.save(&file).unwrap();
        assert_eq!(ChiefSettings::load(&file), s);
        assert!(ChiefSettings::load(&dir.path().join("none.json")).trust_agents);
    }
}
