//! `usageWarnings` in config.json: when a session's usage earns a visible warning
//! (`hub/usage_warnings.rs`): the badge on its cmux NEXT sidebar row and the WARN column of
//! `acpmux ls`. The one place these thresholds live; every client reads the warnings the daemon
//! decided, never its own numbers.

use serde::{Deserialize, Serialize};

/// A call's context above this many tokens warns. A session that never compacts carries its
/// whole history into every call; 400k is past the sr2 `--autocompact` window (380k-420k).
pub const DEFAULT_CONTEXT_TOKENS: u64 = 400_000;
/// More subagents started in the last hour than this warns. Measured 2026-10-30 (the PR that
/// added it has the table): ordinary lanes peaked at 0-9 an hour and the busiest coordinator at
/// 27, while the runaway deputies started 67-90.
pub const DEFAULT_SUBAGENTS_PER_HOUR: u64 = 40;

/// `usageWarnings` in config.json: `{"contextTokens": 400000, "subagentsPerHour": 40,
/// "autocompactCap": true}`. Each threshold 0 (or `autocompactCap` false) turns its rule off.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageWarningsConfig {
    /// `contextTokens`: warn when a call's context is above this. Default 400000.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_tokens: Option<u64>,
    /// `subagentsPerHour`: warn when more subagents than this started in the last hour.
    /// Default 40.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subagents_per_hour: Option<u64>,
    /// `autocompactCap`: warn on a Claude session that runs with no autocompact cap.
    /// Default true.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub autocompact_cap: Option<bool>,
}

/// The thresholds in force: None (or false) is a rule turned off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UsageLimits {
    pub context_tokens: Option<u64>,
    pub subagents_per_hour: Option<u64>,
    pub autocompact_cap: bool,
}

impl Default for UsageLimits {
    fn default() -> Self {
        UsageWarningsConfig::default().limits()
    }
}

impl UsageWarningsConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }

    /// The configured thresholds over their defaults.
    pub fn limits(&self) -> UsageLimits {
        let on = |n: u64| (n > 0).then_some(n);
        UsageLimits {
            context_tokens: on(self.context_tokens.unwrap_or(DEFAULT_CONTEXT_TOKENS)),
            subagents_per_hour: on(self.subagents_per_hour.unwrap_or(DEFAULT_SUBAGENTS_PER_HOUR)),
            autocompact_cap: self.autocompact_cap.unwrap_or(true),
        }
    }
}
