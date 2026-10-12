//! Per-Chief settings, `$MUX_HOME/optchat/settings.json`
//! (`{"remote": {"autoApprove": true}, "cache": {"ttl": "1h"}}`), shown later in the Chief settings
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
    /// configured policy instead of `ask`. Default true (Lawrence,
    /// 2026-10-06: "i dont want stuff to require my approval"); false turns
    /// approvals and the spawn floor back on.
    pub remote_auto_approve: bool,
    /// How long a turn's prompt cache entries live (`5m` or `1h`); None: the
    /// engine's default (1 hour on the Claude Code path, 5 minutes on the
    /// native engine). `OPTCHAT_CACHE_TTL` wins over it.
    pub cache_ttl: Option<CacheTtl>,
}

impl Default for ChiefSettings {
    fn default() -> ChiefSettings {
        ChiefSettings {
            remote_auto_approve: true,
            cache_ttl: None,
        }
    }
}

/// The key of `ChiefSettings::remote_auto_approve`.
pub const REMOTE_AUTO_APPROVE: &str = "remote.autoApprove";

/// The key of `ChiefSettings::cache_ttl`.
pub const CACHE_TTL: &str = "cache.ttl";

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
        }
    }

    pub fn to_json(self) -> Value {
        let mut value = json!({"remote": {"autoApprove": self.remote_auto_approve}});
        if let Some(ttl) = self.cache_ttl {
            value["cache"] = json!({"ttl": ttl.as_str()});
        }
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

/// A boolean setting value: `true` or `false`.
pub fn parse_bool(value: &str) -> Result<bool, String> {
    match value.trim() {
        "true" => Ok(true),
        "false" => Ok(false),
        other => Err(format!("expected true or false, not {other:?}")),
    }
}
