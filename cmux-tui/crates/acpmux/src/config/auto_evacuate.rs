//! `autoEvacuate` in config.json: idle chats leave this machine on their own while it stays over
//! its budget (`hub/auto_evacuate.rs`; the decision is `cmux_host_budget::evacuate`). Off unless
//! `autoEvacuate.enabled` is true: a behaviour that moves people's chats is opt-in.
//! `acpmux config --set auto_evacuate.enabled=true`, or the file, then `acpmux daemon reload`
//! (any config reload) starts its timer; `false` ends it at its next tick.

use cmux_host_budget::Level;
use cmux_host_budget::evacuate::{self, Setting};
use serde::{Deserialize, Serialize};

/// `{"enabled": true, "enter": "warning"|"critical", "holdSecs": 120, "calmSecs": 60,
/// "perTick": 1, "cooldownMinutes": 30, "minIdleMinutes": 5, "keep": ["chat name", ...]}`.
/// Every key but `enabled` has its default when absent.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct AutoEvacuateConfig {
    /// Off (false) by default.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub enabled: bool,
    /// `warning` (the default, the line `place::decide` calls over) or `critical`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enter: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hold_secs: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub calm_secs: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub per_tick: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cooldown_minutes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_idle_minutes: Option<u64>,
    /// Chats, by name, that never move on their own.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub keep: Vec<String>,
}

impl AutoEvacuateConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }

    /// The decision's setting.
    pub fn setting(&self) -> Setting {
        let d = Setting::default();
        Setting {
            on: self.enabled,
            enter: match self.enter.as_deref() {
                Some(e) if e.eq_ignore_ascii_case("critical") => Level::Critical,
                _ => Level::Warning,
            },
            hold_secs: self.hold_secs.unwrap_or(evacuate::DEFAULT_HOLD_SECS),
            calm_secs: self.calm_secs.unwrap_or(evacuate::DEFAULT_CALM_SECS),
            per_tick: self.per_tick.unwrap_or(d.per_tick),
            cooldown_secs: self.cooldown_minutes.map_or(d.cooldown_secs, |m| m.saturating_mul(60)),
            min_idle_secs: self.min_idle_minutes.map_or(d.min_idle_secs, |m| m.saturating_mul(60)),
        }
    }
}
