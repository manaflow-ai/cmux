//! Per-Chief settings, `$MUX_HOME/optchat/settings.json`
//! (`{"remote": {"autoApprove": false}}`), shown later in the Chief settings
//! sidebar. The host reads the file once at start and owns the value after
//! that: a change goes through the host (`Brain::set_setting`), which
//! refuses to turn `remote.autoApprove` on during a remote-origin turn, and
//! writes the file. An edit of the file by hand takes effect at the next
//! host start (README "Remote-origin messages").

use std::path::Path;

use serde_json::{Value, json};

/// The settings this host knows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ChiefSettings {
    /// A remote-origin turn runs with the configured policy instead of
    /// `ask` (default false: every local effect needs an approval).
    pub remote_auto_approve: bool,
}

/// The key of `ChiefSettings::remote_auto_approve`.
pub const REMOTE_AUTO_APPROVE: &str = "remote.autoApprove";

impl ChiefSettings {
    /// The settings in `path`; a missing or unreadable file is the defaults.
    pub fn load(path: &Path) -> ChiefSettings {
        let value: Value = std::fs::read_to_string(path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null);
        ChiefSettings {
            remote_auto_approve: value
                .pointer("/remote/autoApprove")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }
    }

    pub fn to_json(self) -> Value {
        json!({"remote": {"autoApprove": self.remote_auto_approve}})
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

/// A boolean setting value: `true` or `false`.
pub fn parse_bool(value: &str) -> Result<bool, String> {
    match value.trim() {
        "true" => Ok(true),
        "false" => Ok(false),
        other => Err(format!("expected true or false, not {other:?}")),
    }
}
