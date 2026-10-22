//! A Mac's machine id and its other builds' device ids (PROTOCOL.md "Devices"):
//! what lets the phone list one computer once, whatever the names.

use cmux_mobile_host::config::{MAX_SIBLINGS, machine_id, sibling_device_ids};
use cmux_mobile_link::api::DeviceRegistration;

const HOST: [u8; 16] = *b"0123456789abcdef";

#[test]
fn the_machine_id_is_per_computer_and_account_and_hides_the_host_uuid() {
    let id = machine_id("user-1", &HOST);
    assert_eq!(id.len(), 32);
    assert!(id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
    // Every build on the computer derives the same id.
    assert_eq!(machine_id("user-1", &HOST), id);
    // Another computer, or another account on this one: unrelated.
    assert_ne!(machine_id("user-1", b"0123456789abcdeF"), id);
    assert_ne!(machine_id("user-2", &HOST), id);
    // The raw UUID never shows through.
    let raw: String = HOST.iter().map(|b| format!("{b:02x}")).collect();
    assert!(!id.contains(&raw[..8]));
    // Pinned (HMAC-SHA256 computed independently): any other implementation must agree.
    assert_eq!(id, "addf389f53805d18d6846361dbdf0c5e");
}

#[test]
fn siblings_are_the_other_builds_device_ids_on_this_mac() {
    let root = tempfile::tempdir().unwrap();
    let put = |rel: &str, text: &str| {
        let path = root.path().join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    };
    let own = "11111111-1111-4111-8111-111111111111";
    let nightly = "22222222-2222-4222-8222-222222222222";
    let deleted = "33333333-3333-4333-8333-333333333333";
    let standalone = "44444444-4444-4444-8444-444444444444";
    put("com.cmuxterm.app.nightly.cmux-next/cmux-mobile-host/device-id", own);
    put("dev.cmuxterm.app.next.iostest/cmux-mobile-host/device-id", &format!("{}\n", deleted.to_uppercase()));
    put("com.cmuxterm.app.next/cnx-host/device-id", nightly);
    put("cmux-mobile-host/device-id", standalone);
    put("org.other/cmux-mobile-host/device-id", "not a uuid");
    put("org.dupe/cmux-mobile-host/device-id", nightly);
    let ids = sibling_device_ids(root.path(), &own.to_uppercase());
    assert_eq!(ids, vec![standalone.to_owned(), nightly.to_owned(), deleted.to_owned()]);
    assert!(sibling_device_ids(&root.path().join("missing"), own).is_empty());
}

#[test]
fn at_most_sixteen_siblings() {
    let root = tempfile::tempdir().unwrap();
    for n in 0..20u32 {
        let path = root.path().join(format!("b{n:02}/cmux-mobile-host/device-id"));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, uuid::Uuid::new_v4().to_string()).unwrap();
    }
    assert_eq!(sibling_device_ids(root.path(), "x").len(), MAX_SIBLINGS);
}
#[test]
fn a_mac_registration_carries_its_machine_id_and_siblings() {
    let mut registration = DeviceRegistration {
        device_id: "d".into(),
        kind: "mac".into(),
        name: "Mac".into(),
        team_id: "t".into(),
        wg_public_key: None,
        machine_id: Some("ab".repeat(16)),
        sibling_device_ids: vec!["s".into()],
    };
    let body = serde_json::to_value(&registration).unwrap();
    assert_eq!(body["machineId"], "ab".repeat(16));
    assert_eq!(body["siblingDeviceIds"], serde_json::json!(["s"]));
    registration.machine_id = None;
    registration.sibling_device_ids.clear();
    let body = serde_json::to_value(&registration).unwrap();
    assert!(body.get("machineId").is_none() && body.get("siblingDeviceIds").is_none());
}
