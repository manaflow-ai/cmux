//! Per-Chief settings, `$MUX_HOME/optchat/settings.json`
//! (`{"remote": {"autoApprove": false}, "cache": {"ttl": "1h"}}`), shown later in the Chief settings
//! sidebar. The host reads the file once at start and owns the value after
//! that: a change goes through the host (`Brain::set_setting`), which
//! refuses to turn `remote.autoApprove` on during a remote-origin turn, and
//! writes the file. An edit of the file by hand takes effect at the next
//! host start (README "Remote-origin messages").

use std::path::Path;

use serde_json::{Value, json};

use crate::prompt::CacheTtl;

/// The settings this host knows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ChiefSettings {
    /// A remote-origin turn (the owner's own paired device) runs with the
    /// configured policy instead of `ask`. Default false; true is an explicit
    /// opt-in that applies only to that owner's paired devices.
    pub remote_auto_approve: bool,
    /// How long a turn's prompt cache entries live (`5m` or `1h`); None: the
    /// engine's default (1 hour on the Claude Code path, 5 minutes on the
    /// native engine). `OPTCHAT_CACHE_TTL` wins over it.
    pub cache_ttl: Option<CacheTtl>,
    /// When a reply in the Chief's DM goes into the thread of the message it
    /// answers (`replies.thread`). Default `auto`.
    pub reply_threads: ReplyThreads,
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
            remote_auto_approve: false,
            cache_ttl: None,
            reply_threads: ReplyThreads::Auto,
        }
    }
}

/// The key of `ChiefSettings::remote_auto_approve`.
pub const REMOTE_AUTO_APPROVE: &str = "remote.autoApprove";

/// The key of `ChiefSettings::cache_ttl`.
pub const CACHE_TTL: &str = "cache.ttl";

/// The key of `ChiefSettings::reply_threads`.
pub const REPLY_THREADS: &str = "replies.thread";

impl ChiefSettings {
    /// The settings in `path`; a missing or unreadable file is the defaults.
    pub fn load(path: &Path) -> ChiefSettings {
        let value: Value = std::fs::read_to_string(path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null);
        ChiefSettings {
            remote_auto_approve: cmux_chief::policy::remote_auto_approve(&value),
            cache_ttl: value["cache"]["ttl"].as_str().and_then(CacheTtl::parse),
            reply_threads: value["replies"]["thread"]
                .as_str()
                .and_then(ReplyThreads::parse)
                .unwrap_or_default(),
        }
    }

    pub fn to_json(self) -> Value {
        let mut value = json!({"remote": {"autoApprove": self.remote_auto_approve}});
        if let Some(ttl) = self.cache_ttl {
            value["cache"] = json!({"ttl": ttl.as_str()});
        }
        value["replies"] = json!({"thread": self.reply_threads.as_str()});
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
