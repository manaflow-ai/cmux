//! Cache fault accounting per model call (RFD 0182 B6; Leo, 2026-11-25: "Ok well we can't be
//! letting important rfds like that take breaks unless I put in fleet wide pauses, esp when this
//! is stuff that materially improves the app").
//!
//! The prompt cache is a cache like the page cache (RFD 0182 M1), so each main-loop call is
//! classed the way a CPU cache classes its misses, and every policy that buys TTL or refreshes a
//! prefix (B4, B5) can be judged on live counts instead of a replay:
//! - `hit`: the call read at least half of what the call before it left;
//! - `new`: the chat's first call, or one after too little context to miss (`MIN_MISS_CONTEXT`);
//! - `compulsory`: a miss no cache could have served: a compaction since, or a model or effort
//!   change (each has its own cache);
//! - `capacity`: the call came after the cache's TTL lapsed (`expired`);
//! - `conflict`: still warm, same model and effort, no compaction, yet the call read under a
//!   tenth of the context: the prefix was evicted inside its TTL, the signature of an account
//!   switch behind a router (acpmux cannot see the account, so this is inferred);
//! - `churn`: any other miss, a part of the prefix read and the rest rewritten (a prefix edit).
//!
//! Each miss also logs its refault gap, the time since the call before it (workingset's refault
//! distance, M1 (c)): capacity misses that keep landing just past the TTL say the TTL is too short
//! for that chat. The counts go out as `_meta.acpmux.cacheFaults` on each main-loop
//! `usage_update`, so a session's saved usage carries them.

use serde_json::{Value, json};

/// How many miss gaps the median reads (the newest).
pub const GAP_SAMPLES: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    Hit,
    New,
    Compulsory,
    Capacity,
    Conflict,
    Churn,
}

impl Fault {
    pub const ALL: [Fault; 6] =
        [Fault::Hit, Fault::New, Fault::Compulsory, Fault::Capacity, Fault::Conflict, Fault::Churn];

    pub fn key(self) -> &'static str {
        match self {
            Fault::Hit => "hit",
            Fault::New => "new",
            Fault::Compulsory => "compulsory",
            Fault::Capacity => "capacity",
            Fault::Conflict => "conflict",
            Fault::Churn => "churn",
        }
    }

    pub fn is_miss(self) -> bool {
        !matches!(self, Fault::Hit | Fault::New)
    }
}

/// The class of a call that read `read` of the `context` the call before it left, `first` when
/// no call came before, with `cause` the likely cause `prompt_cache::miss_cause` names for it.
pub fn classify(first: bool, context: u64, read: u64, cause: &str) -> Fault {
    if first || context < super::prompt_cache::MIN_MISS_CONTEXT {
        return Fault::New;
    }
    if read.saturating_mul(2) >= context {
        return Fault::Hit;
    }
    match cause {
        "compaction" | "model" | "effort" => Fault::Compulsory,
        "expired" => Fault::Capacity,
        _ if read.saturating_mul(10) < context => Fault::Conflict,
        _ => Fault::Churn,
    }
}

/// A session's cache faults so far.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FaultCounts {
    pub calls: [u64; 6],
    /// Context the misses wrote again instead of reading, per class.
    pub unread_tokens: [u64; 6],
    /// The newest misses' refault gaps in ms, oldest first.
    gaps_ms: std::collections::VecDeque<u64>,
}

impl FaultCounts {
    pub fn record(&mut self, fault: Fault, unread: u64, gap_ms: u64) {
        let at = fault as usize;
        self.calls[at] += 1;
        if fault.is_miss() {
            self.unread_tokens[at] = self.unread_tokens[at].saturating_add(unread);
            if self.gaps_ms.len() == GAP_SAMPLES {
                self.gaps_ms.pop_front();
            }
            self.gaps_ms.push_back(gap_ms);
        }
    }

    pub fn get(&self, fault: Fault) -> u64 {
        self.calls[fault as usize]
    }

    /// The median refault gap of the newest misses, in ms.
    pub fn median_gap_ms(&self) -> Option<u64> {
        let mut gaps: Vec<u64> = self.gaps_ms.iter().copied().collect();
        gaps.sort_unstable();
        gaps.get(gaps.len() / 2).copied()
    }

    /// `_meta.acpmux.cacheFaults`: counts by class, the misses' unread tokens, the median gap.
    pub fn to_json(&self) -> Option<Value> {
        (self.calls.iter().sum::<u64>() > 0).then(|| {
            let mut calls = serde_json::Map::new();
            let mut unread = serde_json::Map::new();
            for fault in Fault::ALL {
                calls.insert(fault.key().into(), json!(self.get(fault)));
                if fault.is_miss() {
                    unread.insert(fault.key().into(), json!(self.unread_tokens[fault as usize]));
                }
            }
            let mut out = json!({"calls": calls, "unreadTokens": unread});
            if let Some(gap) = self.median_gap_ms() {
                out["medianMissGapMs"] = json!(gap);
            }
            out
        })
    }
}

#[cfg(test)]
#[path = "cache_faults_tests.rs"]
mod tests;
