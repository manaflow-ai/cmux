//! `pool` in config.json (the session pool, `hub/pool/`).

use serde::{Deserialize, Serialize};

/// `pool` in config.json: the session pool behind instant harness switches.
/// At most two hidden sessions per cwd (the harness used before the current
/// one, and the one the pane hints at with `_acpmux/prewarm`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct PoolConfig {
    /// Keep pooled sessions at all (they need agent hosts).
    pub enabled: bool,
    /// A pooled session nobody takes or hints at again exits after this many
    /// minutes (at least 1).
    pub idle_minutes: u64,
    /// The whole pool's resident memory cap; the oldest entry goes first.
    pub max_rss_mb: u64,
    /// Stop (SIGSTOP) a ready pooled harness and continue it when taken, for
    /// no idle CPU at all. Off by default: idle exit bounds the cost instead.
    pub park: bool,
    /// `_acpmux/prewarm` hints this close together count once (the last).
    pub debounce_ms: u64,
}

impl Default for PoolConfig {
    fn default() -> Self {
        Self { enabled: true, idle_minutes: 10, max_rss_mb: 1024, park: false, debounce_ms: 150 }
    }
}

impl PoolConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }

    pub fn idle(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.idle_minutes.max(1) * 60)
    }
}
