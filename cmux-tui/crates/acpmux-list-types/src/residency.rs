//! What a chat costs its machine right now, as one versioned record: `residency` on its session
//! summary (`acpmux ls --json`, the v2 list row's `extra`) and the daemon's counts in `acpmux
//! daemon status`. acpmux writes it (`hub/residency.rs`); cmux-tui, NOW's lane caps and admission
//! read it, so a cap counts what holds memory and CPU (a resident harness, a running turn) rather
//! than records, most of which are hibernated chats that cost nothing.
//!
//! Compatibility: a reader takes a record with no `residency` (an older acpmux) as unknown, never
//! as resident or not; one with a higher `v` than [`RESIDENCY_V`] keeps the fields it knows, since a
//! newer writer only adds fields. Every field but `v` is optional on the wire.

use serde::{Deserialize, Serialize};

/// The version this build writes. Bump it only when a field's meaning changes; a new field is
/// optional and needs none.
pub const RESIDENCY_V: u32 = 1;

/// The idle policy that decides when a resident harness hibernates.
#[derive(Clone, Debug, Default, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IdlePolicy {
    /// `static` (one idle period for every chat) or `adaptive-v1` (`hub/residency.rs`).
    #[serde(default)]
    pub name: String,
    /// The idle period this chat waits now, in seconds (the daemon's base period in its status).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_secs: Option<u64>,
}

/// One chat's residency, or a daemon's counts of them.
#[derive(Clone, Debug, Default, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Residency {
    pub v: u32,
    /// A harness process runs for it, holding memory.
    #[serde(default)]
    pub resident: bool,
    /// A turn runs (or waits on a permission): it costs CPU too.
    #[serde(default)]
    pub busy: bool,
    /// When its harness hibernated (ms since the Unix epoch), while it is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hibernated_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<IdlePolicy>,
}

impl Residency {
    /// Reads a summary's `residency` (its `extra` member, or the full summary's field). None from
    /// an older acpmux that writes none, or a value that is not one.
    pub fn of(value: Option<&serde_json::Value>) -> Option<Self> {
        let r: Self = serde_json::from_value(value?.clone()).ok()?;
        (r.v >= 1).then_some(r)
    }

    /// What a cap counts: every resident harness. A hibernated chat holds nothing.
    pub fn counts_for_cap(&self) -> bool {
        self.resident
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn an_older_acpmux_without_residency_is_unknown_not_idle() {
        assert_eq!(Residency::of(None), None);
        assert_eq!(Residency::of(Some(&json!(null))), None);
        assert_eq!(Residency::of(Some(&json!({"resident": true}))), None, "no version: not one");
    }

    #[test]
    fn v1_round_trips_and_counts_only_resident() {
        let r = Residency {
            v: RESIDENCY_V,
            resident: true,
            busy: false,
            hibernated_at: None,
            policy: Some(IdlePolicy { name: "adaptive-v1".into(), idle_secs: Some(1800) }),
        };
        let wire = serde_json::to_value(&r).unwrap();
        assert_eq!(
            wire,
            json!({"v": 1, "resident": true, "busy": false,
                   "policy": {"name": "adaptive-v1", "idleSecs": 1800}})
        );
        assert_eq!(Residency::of(Some(&wire)), Some(r.clone()));
        assert!(r.counts_for_cap());
        assert!(
            !Residency { resident: false, hibernated_at: Some(5), ..r }.counts_for_cap(),
            "a hibernated chat costs nothing"
        );
    }

    #[test]
    fn external_filler_metadata_cannot_exempt_a_resident_chat() {
        let wire = json!({"v": 1, "resident": true, "filler": true});
        let r = Residency::of(Some(&wire)).unwrap();
        assert!(r.counts_for_cap());
        assert!(serde_json::to_value(&r).unwrap().get("filler").is_none());
    }

    #[test]
    fn a_newer_version_keeps_the_fields_this_build_knows() {
        let newer = json!({"v": 2, "resident": true, "busy": true, "gpuMb": 512,
                           "policy": {"name": "adaptive-v2", "idleSecs": 30, "why": "x"}});
        let r = Residency::of(Some(&newer)).expect("a newer record still reads");
        assert_eq!(r.v, 2);
        assert!(r.resident && r.busy && r.counts_for_cap());
        assert_eq!(r.policy.unwrap().name, "adaptive-v2");
    }
}
