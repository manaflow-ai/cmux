//! Whether acpmux brings its own compaction opinions (Leo, 2026-11-26: "we ought to not make
//! jcmux/acpmux so opinionated with compacition. only do it for our personal fleet situation").
//!
//! The compaction acpmux starts by itself was tuned on one fleet's agents and costs, and was on
//! for everyone: compacting an idle chat before its prompt cache lapses (`hub/cache_compact.rs`),
//! compacting a large cold chat before a batched wake (`hub/cold_wake.rs`), masking old tool
//! output in a copy of the transcript (`hub/surgery.rs`) and a 400K autocompact window for every
//! Claude Code chat and terminal `claude` (`harness_limits::CLAUDE_AUTOCOMPACT_WINDOW`).
//!
//! Each of those now defaults to on only under the fleet policy, and to off (Claude Code's own
//! compaction) everywhere else. The fleet policy is `ACPMUX_FLEET_COMPACTION=1` in the process's
//! environment, else `agents.compaction.fleet: true` in the settings file; the environment wins,
//! so `ACPMUX_FLEET_COMPACTION=0` turns it off on one host. Each feature's own setting or
//! variable still wins over the policy either way (`agents.cacheCompact.enabled: true` turns that
//! one on anywhere). A chat that outgrew its window is still compacted and continued for everyone
//! (`hub/auto_resume/compact_first.rs`): that recovers a failed turn and is no tuning choice.

use serde_json::Value;

/// `0|1` in the environment: the fleet policy, whatever the settings file says.
pub const ENV_FLEET: &str = "ACPMUX_FLEET_COMPACTION";
/// The settings-file key for the fleet policy (default `false`).
pub const SETTING_FLEET: &str = "agents.compaction.fleet";

/// An on/off value: `1|true|on|yes` or `0|false|off|no`; anything else says nothing.
pub fn flag(value: Option<&str>) -> Option<bool> {
    match value?.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "on" | "yes" => Some(true),
        "0" | "false" | "off" | "no" => Some(false),
        _ => None,
    }
}

/// The fleet policy as `doc` (the settings file) and `env` have it, the environment winning.
pub fn fleet_with(doc: Option<&Value>, env: impl Fn(&str) -> Option<String>) -> bool {
    flag(env(ENV_FLEET).as_deref())
        .or_else(|| {
            doc.and_then(|d| crate::user_settings::value(d, SETTING_FLEET))
                .and_then(|v| v.as_bool())
        })
        .unwrap_or(false)
}

/// The fleet policy for this process: its environment, then the settings file.
pub fn fleet() -> bool {
    fleet_env(|var| std::env::var(var).ok())
}

/// The fleet policy with `env` for the environment and the settings file read from disk (only
/// when `env` says nothing).
pub fn fleet_env(env: impl Fn(&str) -> Option<String>) -> bool {
    if let Some(on) = flag(env(ENV_FLEET).as_deref()) {
        return on;
    }
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => fleet_with(Some(&doc), |_| None),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn off_unless_the_environment_or_the_settings_say_fleet() {
        assert!(!fleet_with(None, |_| None));
        assert!(!fleet_with(Some(&json!({})), |_| None));
        let on = json!({"agents": {"compaction": {"fleet": true}}});
        assert!(fleet_with(Some(&on), |_| None));
        assert!(fleet_with(None, |v| (v == ENV_FLEET).then(|| "1".into())));
        // The environment wins both ways.
        assert!(!fleet_with(Some(&on), |v| (v == ENV_FLEET).then(|| "0".into())));
    }
}
