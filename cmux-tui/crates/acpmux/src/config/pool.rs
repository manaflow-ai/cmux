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
    /// Most hinted sessions one harness keeps warm across folders; the newest
    /// hint wins. Typing in new chats in several folders keeps this many warm
    /// agents of the harness, not one per folder. 0 counts as 1.
    pub hinted_per_harness: u64,
    /// Keep one spare per harness this machine used: a hidden session of the
    /// shape of its newest session, in that folder, so the next new session
    /// of it is a take instead of a cold start. Also off with
    /// `ACPMUX_SPARE_HARNESS=0` in the daemon's environment.
    pub spare: bool,
    /// A spare nobody takes exits after this many minutes (at least the
    /// pool's `idleMinutes`); the next session of its harness starts it again.
    pub spare_idle_minutes: u64,
}

impl Default for PoolConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            idle_minutes: 10,
            max_rss_mb: 1024,
            park: false,
            debounce_ms: 150,
            hinted_per_harness: 1,
            spare: true,
            spare_idle_minutes: 60,
        }
    }
}

impl PoolConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }

    pub fn idle(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.idle_minutes.max(1) * 60)
    }

    /// How long a spare waits unused: never shorter than `idle`.
    pub fn spare_idle(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.spare_idle_minutes.max(1) * 60).max(self.idle())
    }

    /// Whether spares are on: `spare`, unless the daemon's environment has
    /// `ACPMUX_SPARE_HARNESS` set to 0, false, off or no.
    pub fn spare_enabled(&self) -> bool {
        self.spare && spare_env_allows(std::env::var(SPARE_ENV).ok().as_deref())
    }
}

/// The kill switch for spares in the daemon's environment.
pub const SPARE_ENV: &str = "ACPMUX_SPARE_HARNESS";

/// Whether `value` of `ACPMUX_SPARE_HARNESS` leaves spares on (unset does).
pub fn spare_env_allows(value: Option<&str>) -> bool {
    !value.is_some_and(|v| {
        matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "false" | "off" | "no")
    })
}

#[cfg(test)]
mod spare_tests {
    use super::*;

    #[test]
    fn spare_is_on_by_default_and_the_env_turns_it_off() {
        assert!(PoolConfig::default().spare);
        assert!(spare_env_allows(None));
        assert!(spare_env_allows(Some("1")));
        for off in ["0", "false", "OFF", " no "] {
            assert!(!spare_env_allows(Some(off)), "{off}");
        }
    }

    #[test]
    fn a_spare_never_waits_less_than_the_pool() {
        let cfg = PoolConfig { idle_minutes: 30, spare_idle_minutes: 5, ..Default::default() };
        assert_eq!(cfg.spare_idle(), cfg.idle());
        assert_eq!(PoolConfig::default().spare_idle().as_secs(), 3600);
    }
}
