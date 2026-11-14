use super::*;

fn row(credential: Option<&str>, machine_id: &str) -> Row {
    Row {
        machine_id: machine_id.to_owned(),
        hub_origin: "https://hub.example".to_owned(),
        host_fingerprint: Some("box-a".to_owned()),
        credential: credential.map(str::to_owned),
    }
}

#[test]
fn a_second_entry_never_replaces_the_first() {
    let home = tempfile::tempdir().unwrap();
    let (a, b) = (row(Some("cmm_a"), "machine_a"), row(Some("cmm_b"), "machine_b"));
    queue(home.path(), &a).unwrap();
    queue(home.path(), &b).unwrap();
    // The same credential again is the same entry.
    queue(home.path(), &a).unwrap();
    let mut rows: Vec<Row> = queued(home.path()).unwrap().into_iter().map(|(_, row)| row).collect();
    rows.sort_by(|x, y| x.machine_id.cmp(&y.machine_id));
    assert_eq!(rows, vec![a, b]);
    // A write's leftover temporary file is not an entry.
    for (path, _) in queued(home.path()).unwrap() {
        remove(&path).unwrap();
    }
    std::fs::write(home.path().join(QUEUE).join(".machine-join-x.tmp"), b"{}").unwrap();
    assert!(!any_queued(home.path()));
}

#[test]
fn each_hub_keeps_its_own_revoked_mark() {
    let home = tempfile::tempdir().unwrap();
    let on = |hub: &str| MachineCredential {
        machine_id: "machine".into(),
        hub_origin: hub.into(),
        host_fingerprint: Some("box-a".into()),
        ..Default::default()
    };
    mark_revoked(home.path(), &on("https://hub.example")).unwrap();
    mark_revoked(home.path(), &on("https://other.example")).unwrap();
    clear_revoked(home.path(), "https://other.example");
    assert!(revoked_on(home.path(), "https://hub.example", Some("box-a")));
    assert!(!revoked_on(home.path(), "https://other.example", Some("box-a")));
    assert!(!revoked_on(home.path(), "https://hub.example", Some("box-b")));
}
