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
    /// The most bytes the store's sessions folder may hold (`hub/store_pressure.rs`): over it,
    /// closed chats' logs are compacted and then cold-archived, oldest first, whatever their age,
    /// until it is under again. Default: a quarter of the store's disk; 0: no cap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_bytes: Option<u64>,
    /// The least free space, in percent of the store's disk, before the same pass runs
    /// (`hub/store_pressure.rs`). Default 15; 0: off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_free_percent: Option<u8>,
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

impl StoreConfig {
    /// The store's byte cap on a disk of `disk_total` bytes; None: no cap.
    pub fn store_cap(&self, disk_total: u64) -> Option<u64> {
        match self.max_bytes {
            Some(0) => None,
            Some(bytes) => Some(bytes),
            None if disk_total == 0 => None,
            None => Some(disk_total / 4),
        }
    }

    /// The free-space floor in percent; None: off.
    pub fn free_floor_percent(&self) -> Option<u8> {
        match self.min_free_percent.unwrap_or(15) {
            0 => None,
            percent => Some(percent.min(90)),
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
            max_bytes: None,
            min_free_percent: None,
        }
    }
}
