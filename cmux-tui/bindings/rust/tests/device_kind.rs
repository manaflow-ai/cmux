//! Shared-sizing device kinds (`SizeDeviceKind`): `linux` and `windows` name
//! the GPUI desktop clients next to `mac`, and a kind this SDK does not know
//! decodes as `unknown` instead of failing the whole `size-state`.

use cmux::raw::{SizeDeviceKind, SizeState};
use serde_json::json;

#[test]
fn device_kinds_round_trip_including_linux_and_windows() {
    for raw in ["mac", "iphone", "ipad", "tui", "browser", "linux", "windows", "unknown"] {
        let kind: SizeDeviceKind = serde_json::from_value(json!(raw)).expect(raw);
        assert_eq!(serde_json::to_value(kind).unwrap(), json!(raw));
    }
}

#[test]
fn an_unknown_device_kind_decodes_as_a_generic_client() {
    let kind: SizeDeviceKind = serde_json::from_value(json!("quantum")).unwrap();
    assert_eq!(kind, SizeDeviceKind::Unknown);
    let state: SizeState = serde_json::from_value(json!({
        "generation": 1, "cols": 80, "rows": 24, "reason": "latest", "owners": ["c1"],
        "policy": {"mode": "latest", "priority": [], "fixed": null},
        "participants": [{
            "id": "c1", "user_id": "u1", "display_name": null, "device_kind": "quantum",
            "device_name": null, "device_id": null, "via": null, "viewport": null,
            "counts": true, "counts_override": null, "priority_key": "u1/quantum",
        }],
    }))
    .unwrap();
    assert_eq!(state.participants[0].device_kind, SizeDeviceKind::Unknown);
    // A non-string kind is still a decode error.
    assert!(serde_json::from_value::<SizeDeviceKind>(json!(7)).is_err());
}
