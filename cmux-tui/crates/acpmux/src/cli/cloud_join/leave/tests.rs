use super::*;
use cmux_cloud_client::ApiError;

#[test]
fn a_refusal_says_whether_the_credential_is_dead_or_the_mac_must_revoke() {
    let answer =
        |status: u16, body: &str| classify(&ApiError::from_status(status, body.as_bytes()));
    assert_eq!(
        answer(401, r#"{"code":"machine.revoked"}"#),
        HubAnswer::AlreadyGone { revoked: true }
    );
    assert_eq!(
        answer(401, r#"{"code":"machine.unknown"}"#),
        HubAnswer::AlreadyGone { revoked: false }
    );
    assert_eq!(answer(404, r#"{"code":"machine.not_found"}"#), HubAnswer::Unsupported);
    assert_eq!(answer(404, "<html>no route</html>"), HubAnswer::Unsupported);
    assert_eq!(
        answer(401, r#"{"_tag":"MachineUnauthorized","code":"MachineUnauthorized"}"#),
        HubAnswer::Unsupported
    );
    assert!(matches!(answer(503, "{}"), HubAnswer::Unavailable(_)));
    assert!(matches!(answer(429, "{}"), HubAnswer::Unavailable(_)));
}

fn private(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

#[test]
fn local_removal_takes_only_the_join() {
    let home = tempfile::tempdir().unwrap();
    let record = MachineCredential {
        credential: "cmm_x".into(),
        machine_id: "machine_1".into(),
        name: "box".into(),
        hub_origin: "https://example.com".into(),
        ..Default::default()
    };
    recovery::write_durable(
        &home.path().join(CREDENTIAL_FILE),
        &serde_json::to_vec(&record).unwrap(),
        true,
    )
    .unwrap();
    node_key_for_join_at(home.path()).unwrap();
    std::fs::write(
            home.path().join("config.json"),
            json!({"defaultHarness": "claude", "meshRelay": {"url": "https://example.com", "credential": "join"}})
                .to_string(),
        )
        .unwrap();
    private(&home.path().join("config.json"));
    let removed = remove_local(home.path(), false).unwrap();
    assert_eq!(removed, vec!["meshRelay", "credential", "nodeKey"]);
    assert!(!home.path().join(CREDENTIAL_FILE).exists());
    assert!(!home.path().join("node.wg.key").exists());
    let config: Value =
        serde_json::from_slice(&std::fs::read(home.path().join("config.json")).unwrap()).unwrap();
    assert!(config.get("meshRelay").is_none(), "{config}");
    assert_eq!(config["defaultHarness"], "claude", "the rest of config.json stays");
    // Again: nothing left to remove, and no error.
    assert!(remove_local(home.path(), false).unwrap().is_empty());
    // A token-command relay is not the join's and stays.
    std::fs::write(
        home.path().join("config.json"),
        json!({"meshRelay": {"url": "https://example.com", "tokenCommand": ["mint"]}}).to_string(),
    )
    .unwrap();
    private(&home.path().join("config.json"));
    assert!(remove_local(home.path(), false).unwrap().is_empty());
    let config: Value =
        serde_json::from_slice(&std::fs::read(home.path().join("config.json")).unwrap()).unwrap();
    assert_eq!(config["meshRelay"]["tokenCommand"][0], "mint");
}

#[test]
fn a_leave_deletes_only_a_node_key_its_join_made_and_the_link_did_not_adopt() {
    let record = |home: &Path| {
        let record = MachineCredential {
            credential: "cmm_x".into(),
            machine_id: "machine_1".into(),
            hub_origin: "https://example.com".into(),
            ..Default::default()
        };
        recovery::write_durable(
            &home.join(CREDENTIAL_FILE),
            &serde_json::to_vec(&record).unwrap(),
            true,
        )
        .unwrap();
    };
    let key = |home: &Path| std::fs::read(home.join("node.wg.key")).unwrap();
    // There before the join: the join redeems with it, and its leave keeps it.
    let home = tempfile::tempdir().unwrap();
    crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap();
    let before = key(home.path());
    node_key_for_join_at(home.path()).unwrap();
    assert!(!home.path().join(NODE_KEY_MADE).exists());
    record(home.path());
    assert_eq!(remove_local(home.path(), false).unwrap(), vec!["credential"]);
    assert_eq!(key(home.path()), before);
    // Made by the join, then adopted by the link as its only key: kept, and still the
    // join's ([`NODE_KEY_MADE`] stays with it), so a leave once no adoption depends on it
    // takes it.
    let home = tempfile::tempdir().unwrap();
    node_key_for_join_at(home.path()).unwrap();
    assert!(home.path().join(NODE_KEY_MADE).exists());
    let made = key(home.path());
    std::fs::create_dir_all(home.path().join("link")).unwrap();
    std::fs::write(home.path().join("link/key-adopted.json"), b"{}").unwrap();
    record(home.path());
    assert_eq!(remove_local(home.path(), false).unwrap(), vec!["credential"]);
    assert_eq!(key(home.path()), made);
    assert!(home.path().join(NODE_KEY_MADE).exists());
    std::fs::remove_file(home.path().join("link/key-adopted.json")).unwrap();
    record(home.path());
    assert_eq!(remove_local(home.path(), false).unwrap(), vec!["credential", "nodeKey"]);
    assert_eq!(std::fs::read(home.path().join("node.wg.key")).ok(), None);
    assert!(!home.path().join(NODE_KEY_MADE).exists());
    // A copied home's key is the original box's (or the one put in its place): it goes,
    // whether the record is marked cloned or the caller found the copy.
    for marked in [true, false] {
        let home = tempfile::tempdir().unwrap();
        crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap();
        record(home.path());
        if marked {
            let mut copied = load_at(home.path()).unwrap().unwrap();
            copied.cloned = true;
            save_at(home.path(), &copied).unwrap();
        }
        assert_eq!(remove_local(home.path(), !marked).unwrap(), vec!["credential", "nodeKey"]);
        assert_eq!(std::fs::read(home.path().join("node.wg.key")).ok(), None);
    }
}

/// The node key a join made stays while a cmux link adopted it, and while a running process
/// holds it under the key lock; once neither is so, a leave takes it.
#[test]
fn a_leave_never_deletes_an_adopted_or_held_node_key() {
    use cmux_link::key_holder::KeyHolder;
    let record = |home: &Path| {
        let record = MachineCredential {
            credential: "cmm_x".into(),
            machine_id: "machine_1".into(),
            hub_origin: "https://example.com".into(),
            ..Default::default()
        };
        recovery::write_durable(
            &home.join(CREDENTIAL_FILE),
            &serde_json::to_vec(&record).unwrap(),
            true,
        )
        .unwrap();
    };
    let key = |home: &Path| std::fs::read(home.join("node.wg.key")).ok();
    let home = tempfile::tempdir().unwrap();
    node_key_for_join_at(home.path()).unwrap();
    let made = key(home.path());
    assert!(made.is_some());
    // Adopted by the link: kept.
    std::fs::create_dir_all(home.path().join("link")).unwrap();
    std::fs::write(home.path().join("link/key-adopted.json"), b"{}").unwrap();
    record(home.path());
    assert_eq!(remove_local(home.path(), false).unwrap(), vec!["credential"]);
    assert_eq!(key(home.path()), made);
    std::fs::remove_file(home.path().join("link/key-adopted.json")).unwrap();
    // Held under the key lock (a running link or transport): kept.
    let held = KeyHolder::acquire(home.path()).unwrap();
    record(home.path());
    assert_eq!(remove_local(home.path(), false).unwrap(), vec!["credential"]);
    assert_eq!(key(home.path()), made);
    drop(held);
    // Neither: it goes.
    record(home.path());
    assert_eq!(remove_local(home.path(), false).unwrap(), vec!["credential", "nodeKey"]);
    assert_eq!(key(home.path()), None);
}

/// Review F1 at c1898fca: a sign-out archives the adoption record with its install
/// (`key-adopted.<install>.json`); with the link stopped, a leave still keeps the key that
/// record names, so the install serves it when it signs in again.
#[test]
fn a_leave_keeps_a_node_key_an_archived_adoption_names() {
    let key = |home: &Path| std::fs::read(home.join("node.wg.key")).ok();
    let home = tempfile::tempdir().unwrap();
    node_key_for_join_at(home.path()).unwrap();
    let made = key(home.path());
    std::fs::create_dir_all(home.path().join("link")).unwrap();
    let archived = home.path().join("link/key-adopted.inst_a.json");
    std::fs::write(&archived, serde_json::json!({ "key_dir": home.path() }).to_string()).unwrap();
    assert!(remove_local(home.path(), false).unwrap().is_empty());
    assert_eq!(key(home.path()), made);
    // Archived for another home: this home's key goes.
    let other = tempfile::tempdir().unwrap();
    std::fs::write(&archived, serde_json::json!({ "key_dir": other.path() }).to_string()).unwrap();
    assert_eq!(remove_local(home.path(), false).unwrap(), vec!["nodeKey"]);
    assert_eq!(key(home.path()), None);
}
