use super::*;
use std::os::unix::fs::{PermissionsExt, symlink};

fn pending(joined_by: Option<&str>, capabilities: Option<Vec<String>>) -> Pending {
    Pending {
        version: 1,
        credential: "cmm_x".into(),
        hub: "https://hub.example".into(),
        name: "box".into(),
        hostname: "box".into(),
        platform: "linux".into(),
        wg_public_key: "key".into(),
        prior: None,
        host_fingerprint: None,
        joined_by: joined_by.map(str::to_owned),
        capabilities,
        owner: joined_by.map(|_| "user_me".to_owned()),
    }
}

#[test]
fn a_join_completes_as_what_began_it_whoever_resumes_it() {
    // A sign-in's redeem landed, its probe failed: the proposal stays on disk and says so.
    let begun =
        pending(Some(super::super::enroll::JOINED_BY_SIGN_IN), Some(machine_capabilities()));
    let on_disk = serde_json::to_vec(&begun).unwrap();
    let resumed: Pending = serde_json::from_slice(&on_disk).unwrap();
    let probed = MachineCredential { credential: "cmm_x".into(), ..Default::default() };
    let record = completed_record(&resumed, &probed).unwrap();
    assert_eq!(record.joined_by.as_deref(), Some("sign-in"), "a sign-out then leaves it");
    assert_eq!(record.capabilities, Some(vec!["vault.proxy.v1".to_owned()]));
    // A pasted join line's stays the person's, even when a sign-in finishes it.
    let pasted = completed_record(&pending(None, Some(Vec::new())), &probed).unwrap();
    assert_eq!(pasted.joined_by, None);
    // An older build's proposal: no provenance, no list (the next sign-in rotates once).
    let older: Pending = serde_json::from_value(
        json!({"version":1,"credential":"cmm_x","hub":"https://hub.example","name":"box",
                "hostname":"box","platform":"linux","wg_public_key":"key","prior":null}),
    )
    .unwrap();
    let record = completed_record(&older, &probed).unwrap();
    assert_eq!((record.joined_by, record.capabilities), (None, None));
}

#[test]
fn a_sign_in_join_with_no_redeemed_user_records_the_minting_account() {
    let begun = pending(Some(super::super::enroll::JOINED_BY_SIGN_IN), None);
    // The hub's redeem named no account: the minting account is recorded.
    let probed = MachineCredential { credential: "cmm_x".into(), ..Default::default() };
    let record = completed_record(&begun, &probed).unwrap();
    assert_eq!(record.user_id.as_deref(), Some("user_me"));
    // The hub named the same account: recorded once, the same.
    let same = MachineCredential { user_id: Some("user_me".into()), ..probed.clone() };
    assert_eq!(completed_record(&begun, &same).unwrap().user_id.as_deref(), Some("user_me"));
    // The hub named another: nothing is recorded.
    let other = MachineCredential { user_id: Some("user_b".into()), ..probed.clone() };
    assert!(completed_record(&begun, &other).is_err());
    // A sign-in's proposal from before owners were kept: no account, never the hub's alone.
    let older = Pending { owner: None, ..pending(Some("sign-in"), None) };
    assert_eq!(completed_record(&older, &other).unwrap().user_id, None);
    // A pasted join line's: what the hub says, as before.
    let pasted = pending(None, None);
    assert_eq!(completed_record(&pasted, &other).unwrap().user_id.as_deref(), Some("user_b"));
}

#[test]
fn custom_state_ancestors_are_synced_and_errors_stop_the_commit() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("new/config/state");
    std::fs::create_dir_all(&state).unwrap();
    let canonical = std::fs::canonicalize(&state).unwrap();
    let mut seen = Vec::new();
    sync_ancestors_with(&state, |path| {
        seen.push(path.to_owned());
        Ok(())
    })
    .unwrap();
    assert_eq!(seen, canonical.ancestors().map(Path::to_owned).collect::<Vec<_>>());
    let mut count = 0;
    assert!(
        sync_ancestors_with(&state, |_| {
            count += 1;
            anyhow::ensure!(count < 3, "injected ancestor sync failure");
            Ok(())
        })
        .is_err()
    );
    assert_eq!(count, 3);
}

#[test]
fn durable_pending_is_private_immutable_and_cannot_follow_links() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pending");
    write_durable(&path, b"first", false).unwrap();
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    assert!(write_durable(&path, b"second", false).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"first");
    let link = dir.path().join("link");
    symlink(&path, &link).unwrap();
    assert!(write_durable(&link, b"second", true).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"first");
    write_durable(&path, b"second", true).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), b"second");
}

#[test]
fn colliding_temporary_file_is_neither_truncated_nor_deleted() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("final");
    let temp = dir.path().join("temp");
    std::fs::write(&temp, b"owned by another invocation").unwrap();
    assert!(write_with_temp(&path, b"secret", true, &temp).is_err());
    assert_eq!(std::fs::read(&temp).unwrap(), b"owned by another invocation");
    assert!(!path.exists());
    let link = dir.path().join("link");
    symlink(&temp, &link).unwrap();
    assert!(write_with_temp(&path, b"secret", true, &link).is_err());
    assert!(std::fs::symlink_metadata(link).unwrap().is_symlink());
    assert_eq!(std::fs::read(&temp).unwrap(), b"owned by another invocation");
}
