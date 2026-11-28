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
