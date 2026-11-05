//! The event store's settings (`store` in the config file): where sessions and their logs live,
//! how a log is cut into segments, and how long a closed chat's log is kept whole.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum StoreMode {
    Memory,
    #[default]
    Local,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StoreConfig {
    #[serde(default)]
    pub mode: StoreMode,
    /// Segment roll size in bytes for the event log.
    #[serde(default = "default_segment_bytes")]
    pub segment_bytes: u64,
    /// Days a closed chat's event log is kept whole (`hub/retention.rs`): after them, the
    /// harness's raw lines and long tool output are removed from it, the chat's messages kept.
    /// Default 14; 0 keeps every log whole.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub closed_log_days: Option<u32>,
    /// Every event-log line goes through one append-only journal with group commit
    /// (R-DURABILITY S2, `store/journal_store.rs`): a line is durable within one sync, and a
    /// restart after a crash writes again every line the journal holds past its checkpoint.
    /// Default on.
    #[serde(default = "default_journal")]
    pub journal: bool,
}

impl StoreConfig {
    /// How long a closed chat's log is kept whole; None: always.
    pub fn closed_log_retention(&self) -> Option<std::time::Duration> {
        match self.closed_log_days.unwrap_or(14) {
            0 => None,
            days => Some(std::time::Duration::from_secs(u64::from(days) * 86_400)),
        }
    }
}

fn default_segment_bytes() -> u64 {
    8 * 1024 * 1024
}

fn default_journal() -> bool {
    true
}

impl Default for StoreConfig {
    fn default() -> Self {
        Self {
            mode: StoreMode::Local,
            segment_bytes: default_segment_bytes(),
            closed_log_days: None,
            journal: true,
        }
    }
}

/// Whether `store.journal` is on in this home's config file, read without loading the rest of the
/// config (no harness discovery): the daemon's process tier is set before it starts any thread
/// (`qos::enter_daemon`). A file that is missing or does not read counts as off, the default; the
/// daemon's own config load then reports the error.
pub fn store_journal_enabled() -> bool {
    #[derive(Deserialize)]
    struct File {
        #[serde(default)]
        store: Option<Store>,
    }
    #[derive(Deserialize)]
    struct Store {
        #[serde(default = "default_journal")]
        journal: bool,
    }
    let path = super::Config::path();
    let Ok(mut file) = super::private_state_file(&path) else { return true };
    let mut text = String::new();
    if std::io::Read::read_to_string(&mut file, &mut text).is_err() {
        return true;
    }
    serde_json::from_str::<File>(&text).ok().and_then(|file| file.store).is_none_or(|s| s.journal)
}
