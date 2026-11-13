//! A Mac's machine id and its other builds' device ids (PROTOCOL.md "Devices"):
//! what lets the phone list one computer once, whatever the names.

use cmux_mobile_host::config::{HostUuid, MACHINE_MARKER, MAX_SIBLINGS, machine_id, normalize_machine_id, registration_machine, registration_siblings, sibling_device_ids};
use cmux_mobile_link::api::DeviceRegistration;

const HOST: [u8; 16] = *b"0123456789abcdef";
const MINE: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

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
    let ids = sibling_device_ids(root.path(), "owner", &own.to_uppercase(), MINE);
    assert_eq!(ids, vec![standalone.to_owned(), nightly.to_owned(), deleted.to_owned()]);
    assert!(sibling_device_ids(&root.path().join("missing"), "owner", own, MINE).is_empty());
}

#[test]
fn at_most_sixteen_siblings() {
    let root = tempfile::tempdir().unwrap();
    for n in 0..20u32 {
        let path = root.path().join(format!("b{n:02}/cmux-mobile-host/device-id"));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, uuid::Uuid::new_v4().to_string()).unwrap();
    }
    assert_eq!(sibling_device_ids(root.path(), "owner", "x", MINE).len(), MAX_SIBLINGS);
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

/// A folder that says it belongs to another machine (it came over with
/// Migration Assistant or a restore) is not this Mac's build; one that says
/// this machine, or says nothing (a build from before machine ids), is.
#[test]
fn a_folder_from_another_machine_is_not_a_sibling() {
    let root = tempfile::tempdir().unwrap();
    let put = |rel: &str, text: &str| {
        let path = root.path().join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    };
    let migrated = "55555555-5555-4555-8555-555555555555";
    let same = "66666666-6666-4666-8666-666666666666";
    let legacy = "77777777-7777-4777-8777-777777777777";
    put("a.migrated/cmux-mobile-host/device-id", migrated);
    put(&format!("a.migrated/cmux-mobile-host/{MACHINE_MARKER}"), "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2");
    put("b.same/cmux-mobile-host/device-id", same);
    put(&format!("b.same/cmux-mobile-host/{MACHINE_MARKER}"), &MINE.to_uppercase());
    put("c.legacy/cmux-mobile-host/device-id", legacy);
    assert_eq!(
        sibling_device_ids(root.path(), "owner", "own", MINE),
        vec![same.to_owned(), legacy.to_owned()]
    );
}

#[test]
fn an_override_must_be_a_machine_id() {
    assert_eq!(normalize_machine_id(" A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1 ").as_deref(), Some(MINE));
    assert_eq!(normalize_machine_id("a1"), None);
    assert_eq!(normalize_machine_id(&"z".repeat(32)), None);
}

#[test]
fn the_host_uuid_never_prints() {
    assert_eq!(format!("{:?}", HostUuid(HOST)), "HostUuid(<redacted>)");
}

/// A machine id override (a hidden test rig, #24701) says "this build is its
/// own computer": it has no siblings on the real Mac. Sending them would make
/// the backend give the rig's made-up id to every same-owner record with none
/// yet (old builds, other rigs), folding them into the rig for good.
#[test]
fn an_overridden_machine_id_claims_no_siblings() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("old.build/cmux-mobile-host/device-id");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, "88888888-8888-4888-8888-888888888888").unwrap();
    assert_eq!(
        registration_siblings(root.path(), "owner", "own", MINE, false),
        vec!["88888888-8888-4888-8888-888888888888".to_owned()]
    );
    assert!(registration_siblings(root.path(), "owner", "own", MINE, true).is_empty());
}

/// The registration itself: an override sends no siblings and writes no
/// marker; this computer's own id sends them and writes its marker.
#[test]
fn a_registration_with_an_override_sends_no_siblings_and_writes_no_marker() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("old.build/cmux-mobile-host/device-id");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, "99999999-9999-4999-8999-999999999999").unwrap();
    let state = root.path().join("rig.app/cmux-mobile-host");
    let (id, siblings) = registration_machine(Some(MINE.into()), true, &state, root.path(), "owner", "own");
    assert_eq!(id.as_deref(), Some(MINE));
    assert!(siblings.is_empty());
    assert!(!state.join(MACHINE_MARKER).exists());
    let (_, siblings) = registration_machine(Some(MINE.into()), false, &state, root.path(), "owner", "own");
    assert_eq!(siblings, vec!["99999999-9999-4999-8999-999999999999".to_owned()]);
    assert_eq!(std::fs::read_to_string(state.join(MACHINE_MARKER)).unwrap(), MINE);
}

/// Since the Mac app keeps a device id per account (`device-id.<owner>`), a build's id for this
/// owner is its sibling; another account's id in the same folder is never read, and an id whose
/// `.machine` names another computer (a copied folder) is skipped.
#[test]
fn per_account_ids_are_read_for_this_owner_only() {
    let root = tempfile::tempdir().unwrap();
    let put = |rel: &str, text: &str| {
        let path = root.path().join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    };
    let mine = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    let theirs = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    let copied = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    put("com.cmuxterm.app.nightly/cmux-mobile-host/device-id.owner", mine);
    put("com.cmuxterm.app.nightly/cmux-mobile-host/device-id.owner.machine", MINE);
    put("com.cmuxterm.app.nightly/cmux-mobile-host/device-id.someone-else", theirs);
    put("com.cmuxterm.app.debug.x/cmux-mobile-host/device-id.owner", copied);
    put(
        "com.cmuxterm.app.debug.x/cmux-mobile-host/device-id.owner.machine",
        "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2",
    );
    assert_eq!(sibling_device_ids(root.path(), "owner", "own", MINE), vec![mine.to_owned()]);
    assert!(cmux_mobile_host::config::owner_file_component("../x").is_none());
}
