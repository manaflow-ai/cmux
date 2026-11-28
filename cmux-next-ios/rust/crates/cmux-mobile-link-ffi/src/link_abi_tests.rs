use super::{
    PHONE_ABI, PHONE_ABI_MIN, PhoneAbiRange, PhoneUpdateSide, phone_abi_check, phone_abi_range,
    phone_abi_refusal,
};
use serde_json::{Value, json};

fn reply(meta: Value) -> String {
    json!({"protocolVersion": 1, "_meta": {"acpmux": meta}}).to_string()
}

/// The phone reads every revision acpmux's compat file names: its newest is `PHONE_ABI`. A new
/// revision there fails this until someone checks the phone against it and raises the constant.
#[test]
fn phone_abi_is_the_compat_files_newest_revision() {
    let compat: Value = serde_json::from_str(include_str!(
        "../../../../../cmux-tui/crates/acpmux/spec/acpmux-abi.compat.json"
    ))
    .unwrap();
    let newest = compat["revisions"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["rev"].as_u64())
        .max()
        .unwrap_or_else(|| compat["base"].as_u64().unwrap());
    assert_eq!(u64::from(PHONE_ABI), newest);
}

/// N-1 and N+1 both work: the window always holds the revision before the newest.
#[test]
fn the_window_keeps_n_minus_1() {
    assert!(PHONE_ABI_MIN < PHONE_ABI);
    assert_eq!(phone_abi_range(), PhoneAbiRange { min: PHONE_ABI_MIN, max: PHONE_ABI });
}

#[test]
fn a_mac_from_before_the_fields_is_served() {
    assert_eq!(phone_abi_check(reply(json!({"version": "0.1"}))), None);
    assert_eq!(phone_abi_check(json!({}).to_string()), None);
    assert_eq!(phone_abi_check("not json".into()), None);
}

#[test]
fn an_overlapping_mac_is_served() {
    // The same build, one older (N-1), one newer that still serves us (N+1).
    for meta in [
        json!({"abi": PHONE_ABI, "abiMin": 0}),
        json!({"abi": PHONE_ABI - 1}),
        json!({"abi": PHONE_ABI + 1, "abiMin": PHONE_ABI}),
    ] {
        assert_eq!(phone_abi_check(reply(meta.clone())), None, "{meta}");
    }
}

#[test]
fn a_newer_mac_that_dropped_ours_names_the_phone() {
    let got = phone_abi_check(reply(json!({"abi": PHONE_ABI + 3, "abiMin": PHONE_ABI + 1}))).unwrap();
    assert_eq!(got.side, PhoneUpdateSide::Phone);
    assert_eq!(got.mac, Some(PhoneAbiRange { min: PHONE_ABI + 1, max: PHONE_ABI + 3 }));
    assert!(got.reason.starts_with("Update the cmux app"));
    assert!(got.reason.len() < 80);
}

#[test]
fn an_abi_min_above_abi_reads_as_abi_alone() {
    // A malformed floor is ignored: abi 2 alone overlaps.
    assert_eq!(phone_abi_check(reply(json!({"abi": PHONE_ABI, "abiMin": 99}))), None);
}

/// The Mac's own refusal (acpmux `protocol::range::refusal`'s data) maps `peer` to this phone.
#[test]
fn the_macs_refusal_names_the_side() {
    let peer = json!({
        "errorKind": "version.incompatible",
        "recovery": "this client is older than this build serves",
        "details": {"ours": {"min": 5, "max": 6}, "theirs": {"min": 0, "max": 2}, "update": "peer"},
    });
    let got = phone_abi_refusal(peer.to_string()).unwrap();
    assert_eq!(got.side, PhoneUpdateSide::Phone);
    assert_eq!(got.mac, Some(PhoneAbiRange { min: 5, max: 6 }));

    let own = json!({"errorKind": "version.incompatible", "details": {"update": "self"}});
    let got = phone_abi_refusal(own.to_string()).unwrap();
    assert_eq!(got.side, PhoneUpdateSide::Mac);
    assert!(got.reason.starts_with("Update cmux on your Mac"));
    assert!(got.reason.len() < 80);
}

#[test]
fn other_refusals_are_not_version_refusals() {
    assert_eq!(phone_abi_refusal(json!({"errorKind": "busy"}).to_string()), None);
    assert_eq!(phone_abi_refusal(json!({"reason": "x"}).to_string()), None);
    assert_eq!(phone_abi_refusal("".into()), None);
}
