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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ChiefSettings {
    /// How long a turn's prompt cache entries live (`5m` or `1h`); None: the
    /// engine's default (1 hour on the Claude Code path, 5 minutes on the
    /// native engine). `OPTCHAT_CACHE_TTL` wins over it.
    pub cache_ttl: Option<CacheTtl>,
    /// When a reply in the Chief's DM goes into the thread of the message it
    /// answers (`replies.thread`). Default `auto`.
    pub reply_threads: ReplyThreads,
    /// A subagent's report that names landed commits, pages or preview files
    /// gets a `<show>` block for the Chief to open them in the column right of
    /// its chat (`show.afterReport`, crate::show). Default true.
    pub show_after_report: bool,
    /// Each subagent gets a sidebar workspace when it starts
    /// (`subagents.showWorkspaces`). Default false (#26386): subagents run
    /// hidden, reachable from their links in the Chief's replies, and
    /// `control show ID` / `control hide ID` add or close one's workspace.
    pub show_subagent_workspaces: bool,
    /// Seconds a cloud VM waits with no live cloud subagent before the host
    /// pauses it (`cloud.autoPauseIdleSeconds`, cloud-subagents-DESIGN.md
    /// B4). Default 60.
    pub cloud_auto_pause_idle_secs: u64,
    /// Days a finished subagent's own VM stays paused (for a later tell)
    /// before the host deletes it (`cloud.deleteAfterPausedDays`,
    /// cloud-subagents-DESIGN.md v2).
    pub cloud_delete_after_paused_days: u64,
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
            reply_threads: ReplyThreads::Auto,
            show_after_report: true,
            show_subagent_workspaces: false,
            cloud_auto_pause_idle_secs: 60,
            cloud_delete_after_paused_days: 7,
        }
    }
}

/// The key of `ChiefSettings::cache_ttl`.
pub const CACHE_TTL: &str = "cache.ttl";

/// The key of `ChiefSettings::reply_threads`.
pub const REPLY_THREADS: &str = "replies.thread";

/// The key of `ChiefSettings::show_after_report`.
pub const SHOW_AFTER_REPORT: &str = "show.afterReport";

/// The key of `ChiefSettings::show_subagent_workspaces`.
pub const SHOW_SUBAGENT_WORKSPACES: &str = "subagents.showWorkspaces";

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
            reply_threads: value["replies"]["thread"]
                .as_str()
                .and_then(ReplyThreads::parse)
                .unwrap_or_default(),
            show_after_report: value["show"]["afterReport"].as_bool().unwrap_or(true),
            show_subagent_workspaces: value["subagents"]["showWorkspaces"]
                .as_bool()
                .unwrap_or(false),
            cloud_auto_pause_idle_secs: value["cloud"]["autoPauseIdleSeconds"]
                .as_u64()
                .unwrap_or(60),
            cloud_delete_after_paused_days: value["cloud"]["deleteAfterPausedDays"]
                .as_u64()
                .unwrap_or(7),
        }
    }

    pub fn to_json(self) -> Value {
        let mut value = json!({});
        if let Some(ttl) = self.cache_ttl {
            value["cache"] = json!({"ttl": ttl.as_str()});
        }
        value["replies"] = json!({"thread": self.reply_threads.as_str()});
        value["show"] = json!({"afterReport": self.show_after_report});
        value["subagents"] = json!({"showWorkspaces": self.show_subagent_workspaces});
        value["cloud"] = json!({
            "autoPauseIdleSeconds": self.cloud_auto_pause_idle_secs,
            "deleteAfterPausedDays": self.cloud_delete_after_paused_days,
        });
        value
    }

    /// Writes the settings (0600, through a temporary file and a rename).
    pub fn save(self, path: &Path) -> std::io::Result<()> {
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
