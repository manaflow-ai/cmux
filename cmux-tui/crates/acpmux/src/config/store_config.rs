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

impl Default for StoreConfig {
    fn default() -> Self {
        Self {
            mode: StoreMode::Local,
            segment_bytes: default_segment_bytes(),
            closed_log_days: None,
        }
    }
}
