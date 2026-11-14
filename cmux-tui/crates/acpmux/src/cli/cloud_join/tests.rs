use super::{MachineCredential, MachineIdentity, origin, parse_token_text};

#[test]
fn join_token_is_shell_safe_after_shared_line_reader() {
    assert_eq!(parse_token_text("cmj_abc-123_").unwrap(), "cmj_abc-123_");
    assert!(parse_token_text("cmj_abc!").is_err());
    assert!(parse_token_text("cmj_").is_err());
    assert!(parse_token_text("cmxt1_ticket").is_err());
}
#[test]
fn join_origin_cannot_carry_secrets_paths_or_non_http_schemes() {
    for url in [
        "https://secret@example.com",
        "https://example.com/path",
        "https://example.com?token=secret",
        "ftp://localhost",
        "http://example.com",
    ] {
        let error = origin(Some(url.to_owned())).unwrap_err().to_string();
        assert!(!error.contains("secret"));
    }
    assert_eq!(origin(Some("https://EXAMPLE.com:443/".to_owned())).unwrap(), "https://example.com");
    assert!(origin(Some("http://127.0.0.1:1234".to_owned())).is_ok());
}

#[cfg(unix)]
fn joined_on(home: &std::path::Path, fingerprint: Option<&str>) -> Vec<u8> {
    let record = super::MachineCredential {
        credential: "cmm_original".into(),
        machine_id: "machine_original".into(),
        team_id: "team".into(),
        name: "original".into(),
        hub_origin: "https://example.com".into(),
        wg_public_key: "original-key".into(),
        credential_generation: 1,
        host_fingerprint: fingerprint.map(str::to_owned),
        ..Default::default()
    };
    super::save_at(home, &record).unwrap();
    crate::cli::mesh_node_key::load_or_create_at(home).unwrap();
    std::fs::read(home.join("node.wg.key")).unwrap()
}

/// Review F2 at 9e91bcea: the clone check the cmux link shares, by the home it names.
/// A copy whose key could not be replaced (not marked yet) is a copy, as is a marked one;
/// the box that joined, an unjoined home and an unknown box are not.
#[test]
#[cfg(unix)]
fn the_shared_clone_check_reads_the_named_home() {
    let home = tempfile::tempdir().unwrap();
    assert!(!super::copied_at(home.path(), Some("box-b")), "not joined");
    joined_on(home.path(), Some("box-a"));
    assert!(!super::copied_at(home.path(), Some("box-a")));
    assert!(!super::copied_at(home.path(), None));
    assert!(super::copied_at(home.path(), Some("box-b")), "an unsettled copy");
    let mut record = super::load_at(home.path()).unwrap().unwrap();
    record.cloned = true;
    super::save_at(home.path(), &record).unwrap();
    assert!(super::copied_at(home.path(), Some("box-a")) && super::copied_at(home.path(), None));
}

/// Review F1 at d1e8f0ed: a copy found and not settled records its node key as copied
/// before anything else, so a leave that then deletes the record (and keeps the key the
/// link adopted) leaves the evidence behind; a settled copy's fresh key is never recorded.
#[test]
#[cfg(unix)]
fn a_found_copy_is_recorded_before_a_leave_removes_its_record() {
    use crate::cli::mesh_node_key::{COPIED_KEY, serves_copied_key};
    let home = tempfile::tempdir().unwrap();
    joined_on(home.path(), Some("box-a"));
    // The link adopted the key: a leave keeps it.
    std::fs::create_dir_all(home.path().join("link")).unwrap();
    let record = serde_json::json!({ "key_dir": home.path() });
    std::fs::write(home.path().join("link/key-adopted.json"), record.to_string()).unwrap();
    assert!(!serves_copied_key(home.path()));
    assert!(super::copied_at(home.path(), Some("box-b")));
    assert!(serves_copied_key(home.path()), "the found copy was not recorded");
    let removed = super::leave::remove_local(home.path(), false).unwrap();
    assert!(removed.contains(&"credential") && !removed.contains(&"nodeKey"), "{removed:?}");
    assert!(super::copied_at(home.path(), Some("box-b")), "the leave erased the evidence");
    assert!(super::copied_at(home.path(), None));
    // The settled path: recorded before the replacement, which then names the old key.
    let settled = tempfile::tempdir().unwrap();
    joined_on(settled.path(), Some("box-a"));
    assert_eq!(
        super::settle_clone_at(settled.path(), Some("box-b")).unwrap(),
        super::CloneCheck::Cloned
    );
    assert!(settled.path().join(COPIED_KEY).is_file());
    assert!(!serves_copied_key(settled.path()), "the fresh key is this box's");
    // A record already settled (`cloned`) names a fresh key: never recorded as copied.
    let fresh = tempfile::tempdir().unwrap();
    joined_on(fresh.path(), Some("box-a"));
    let mut record = super::load_at(fresh.path()).unwrap().unwrap();
    record.cloned = true;
    super::save_at(fresh.path(), &record).unwrap();
    assert!(super::copied_at(fresh.path(), Some("box-b")));
    assert!(!fresh.path().join(COPIED_KEY).exists());
}

/// Review F1 at 6b797bbf: a copy settled on box B (fresh key B) and copied again to C,
/// as it was or after B joined again, is found and settled again on C, and every copied
/// key stays named; B itself keeps its key.
#[test]
#[cfg(unix)]
fn a_copy_of_a_settled_copy_is_found_and_settled_again() {
    use crate::cli::mesh_node_key::{public_key_at, serves_copied_key};
    for rejoined in [false, true] {
        let home = tempfile::tempdir().unwrap();
        joined_on(home.path(), Some("box-a"));
        let key_a = public_key_at(home.path()).unwrap();
        assert_eq!(
            super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
            super::CloneCheck::Cloned
        );
        let key_b = public_key_at(home.path()).unwrap();
        assert_ne!(key_b, key_a);
        if rejoined {
            let mut record = super::load_at(home.path()).unwrap().unwrap();
            record.cloned = false;
            record.cloned_on = None;
            record.host_fingerprint = Some("box-b".into());
            super::save_at(home.path(), &record).unwrap();
        }
        // B: its own key, settled or joined there.
        let on_b = super::load_at(home.path()).unwrap().unwrap();
        assert_ne!(
            super::copy_state(home.path(), &on_b, Some("box-b")),
            super::CopyState::Unsettled
        );
        assert!(!serves_copied_key(home.path()), "B's own key is named copied");
        assert_eq!(
            super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
            if rejoined { super::CloneCheck::Same } else { super::CloneCheck::AlreadyCloned }
        );
        assert_eq!(public_key_at(home.path()), Some(key_b));
        // C: found live, recorded, and settled with a key of its own.
        let on_c = super::load_at(home.path()).unwrap().unwrap();
        assert_eq!(
            super::copy_state(home.path(), &on_c, Some("box-c")),
            super::CopyState::Unsettled
        );
        assert!(super::copied_here(home.path(), &on_c, Some("box-c")));
        assert!(serves_copied_key(home.path()), "the copy of the copy was not recorded");
        assert_eq!(
            super::settle_clone_at(home.path(), Some("box-c")).unwrap(),
            super::CloneCheck::Cloned,
            "rejoined {rejoined}"
        );
        let key_c = public_key_at(home.path()).unwrap();
        assert!(key_c != key_a && key_c != key_b);
        let named: serde_json::Value = serde_json::from_slice(
            &std::fs::read(home.path().join(crate::cli::mesh_node_key::COPIED_KEY)).unwrap(),
        )
        .unwrap();
        let named = named["public_keys"].as_array().unwrap().len();
        assert_eq!(named, 2, "both copied keys stay named (rejoined {rejoined})");
        assert!(!serves_copied_key(home.path()));
    }
}

/// A join begun on `box` and not finished, in `home`: `machine-join.pending.json`.
#[cfg(unix)]
fn pending_on(home: &std::path::Path, made: &str) {
    use std::os::unix::fs::OpenOptionsExt as _;
    let pending = serde_json::json!({"version": 1, "credential": "cmm_x", "hub": "https://example.com",
            "name": "original", "hostname": "original", "platform": "linux", "wg_public_key": "k",
            "prior": null, "host_fingerprint": made});
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(home.join("machine-join.pending.json"))
        .unwrap();
    std::io::Write::write_all(&mut file, pending.to_string().as_bytes()).unwrap();
}

/// Review F1 at 2d63280a: the daemon's start on a copied home reads its evidence (the node
/// key recorded as copied), then a `host join` runs before the start acts: under the join
/// lock it replaces the copied key and registers a new one. The start then acts under the
/// same lock, by compare-and-replace, and keeps the registered key.
#[test]
#[cfg(unix)]
fn a_start_on_a_copied_home_racing_a_host_join_keeps_the_registered_key() {
    use crate::cli::mesh_node_key::{
        load_or_create_at, public_key_at, record_copied_key, replace_copied_at, serves_copied_key,
    };
    use base64::Engine as _;
    let home = tempfile::tempdir().unwrap();
    let copied = load_or_create_at(home.path()).unwrap().public_key;
    record_copied_key(home.path()).unwrap();
    let registered = std::rc::Rc::new(std::cell::Cell::new(None));
    let joined = std::rc::Rc::clone(&registered);
    let dir = home.path().to_path_buf();
    super::hooks::AFTER_EVIDENCE.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || {
            // What `host join` does, under its lock: the copied key replaced, the new one
            // proposed and registered (`new_pending`, then `complete`).
            let _lock = super::join_lock_in(&dir).unwrap();
            let fresh = replace_copied_at(&dir).unwrap().unwrap().public_key;
            let record = super::MachineCredential {
                credential: "cmm_here".into(),
                machine_id: "machine_here".into(),
                team_id: "team".into(),
                name: "here".into(),
                hub_origin: "https://example.com".into(),
                wg_public_key: base64::engine::general_purpose::STANDARD.encode(fresh),
                credential_generation: 1,
                host_fingerprint: super::host_fingerprint::current(),
                ..Default::default()
            };
            super::save_at(&dir, &record).unwrap();
            joined.set(Some(fresh));
        }));
    });
    super::settle_clone_at_start_in(home.path()).unwrap();
    let registered = registered.get().expect("the join ran");
    assert_ne!(registered, copied);
    assert_eq!(public_key_at(home.path()), Some(registered), "the start deleted the join's key");
    assert!(!serves_copied_key(home.path()));
    // With no join in between, the start replaces the copied key itself.
    let alone = tempfile::tempdir().unwrap();
    let copied = load_or_create_at(alone.path()).unwrap().public_key;
    record_copied_key(alone.path()).unwrap();
    super::settle_clone_at_start_in(alone.path()).unwrap();
    assert!(public_key_at(alone.path()).is_some_and(|now| now != copied));
}

/// Review F1 at fb84fe4b: a cmux link refused this copied home and stopped before it
/// recorded the copied key (its refusal names the key, or none). acpmux's start reads the
/// refusal, finishes the recording and replaces the key: the copied key never serves.
#[test]
#[cfg(unix)]
fn a_link_refusal_with_no_recorded_key_is_finished_and_the_key_replaced_at_start() {
    use crate::cli::mesh_node_key::{
        COPIED_KEY, LINK_COPIED, load_or_create_at, public_key_at, serves_copied_key,
    };
    use base64::Engine as _;
    for named in [true, false] {
        let home = tempfile::tempdir().unwrap();
        let copied = load_or_create_at(home.path()).unwrap().public_key;
        let copied_b64 = base64::engine::general_purpose::STANDARD.encode(copied);
        // The link dir acpmux finds for this home in tests (`link_dirs_for`).
        let link = home.path().join("link");
        std::fs::create_dir_all(&link).unwrap();
        let mut refusal = serde_json::json!({ "acpmux_home": home.path() });
        if named {
            refusal["public_key"] = serde_json::json!(copied_b64);
        }
        std::fs::write(link.join(LINK_COPIED), refusal.to_string()).unwrap();
        assert!(!home.path().join(COPIED_KEY).exists());
        assert!(serves_copied_key(home.path()), "named {named}");
        assert!(super::copied_from_another_box_at(home.path()));
        super::settle_clone_at_start_in(home.path()).unwrap();
        let recorded = std::fs::read_to_string(home.path().join(COPIED_KEY)).unwrap();
        assert!(recorded.contains(&copied_b64), "the refusal was not finished: {recorded}");
        assert!(public_key_at(home.path()).is_some_and(|now| now != copied), "named {named}");
        if named {
            assert!(!serves_copied_key(home.path()), "the fresh key is this box's");
        }
    }
}

/// Review F1 at 2d63280a, the readers: a caller that read the copy's record before the box
/// settled it and joined again never marks the registered key that replaced the copy's.
#[test]
#[cfg(unix)]
fn a_record_read_before_a_settle_and_rejoin_never_marks_the_new_key() {
    use crate::cli::mesh_node_key::{public_key_at, serves_copied_key};
    let home = tempfile::tempdir().unwrap();
    joined_on(home.path(), Some("box-a"));
    let stale = super::load_at(home.path()).unwrap().unwrap();
    // Box B settles under the join lock, then joins again with its fresh key.
    assert!(matches!(
        super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
        super::CloneCheck::Cloned
    ));
    assert!(!serves_copied_key(home.path()));
    let mut rejoined = stale.clone();
    rejoined.cloned = false;
    rejoined.cloned_on = None;
    rejoined.host_fingerprint = Some("box-b".into());
    super::save_at(home.path(), &rejoined).unwrap();
    let fresh = public_key_at(home.path()).unwrap();
    // The stale reader still answers that its record was a copy, and marks nothing new.
    assert!(super::copied_here(home.path(), &stale, Some("box-b")));
    assert!(!serves_copied_key(home.path()), "the registered key was marked copied");
    assert_eq!(public_key_at(home.path()), Some(fresh));
}

/// Review F1 at 7837efd1: a home with a node key and a join begun on another box, with no
/// machine record yet, is a copy to every caller of the one predicate (the link's adoption
/// check, the daemon, `host join`'s set-aside); the box that began it is not.
#[test]
#[cfg(unix)]
fn a_pending_join_begun_on_another_box_makes_the_home_a_copy_for_every_caller() {
    use crate::cli::mesh_node_key::{load_or_create_at, serves_copied_key};
    let home = tempfile::tempdir().unwrap();
    crate::config::private_state_dir(home.path()).unwrap();
    load_or_create_at(home.path()).unwrap();
    pending_on(home.path(), "box-a");
    assert!(super::load_at(home.path()).unwrap().is_none(), "no record");
    assert_eq!(super::home_copy_state(home.path(), None, Some("box-a")), super::CopyState::Own);
    assert!(!super::copied_at(home.path(), Some("box-a")));
    assert!(!serves_copied_key(home.path()));
    assert_eq!(
        super::home_copy_state(home.path(), None, Some("box-b")),
        super::CopyState::Unsettled
    );
    assert!(super::copied_at(home.path(), Some("box-b")));
    assert!(serves_copied_key(home.path()), "the copy was not recorded");
    // `host join`'s comparison is the same one.
    assert!(super::other_box(home.path(), Some("box-a"), Some("box-b")));
    assert!(!super::other_box(home.path(), Some("box-a"), Some("box-a")));
    // A record joined here does not hide a pending join copied from elsewhere.
    let mine =
        super::MachineCredential { host_fingerprint: Some("box-b".into()), ..Default::default() };
    assert!(super::copied_here(home.path(), &mine, Some("box-b")));
}

#[test]
#[cfg(unix)]
fn the_box_that_joined_keeps_its_credential_and_key() {
    let home = tempfile::tempdir().unwrap();
    let key = joined_on(home.path(), Some("box-a"));
    assert_eq!(
        super::settle_clone_at(home.path(), Some("box-a")).unwrap(),
        super::CloneCheck::Same
    );
    let record = super::load_at(home.path()).unwrap().unwrap();
    assert!(!record.cloned && !super::copied_here(home.path(), &record, Some("box-a")));
    assert_eq!(std::fs::read(home.path().join("node.wg.key")).unwrap(), key);
}

#[test]
#[cfg(unix)]
fn a_copied_home_is_marked_cloned_with_a_fresh_key_and_the_credential_left_as_it_was() {
    let home = tempfile::tempdir().unwrap();
    let key = joined_on(home.path(), Some("box-a"));
    let before = super::load_at(home.path()).unwrap().unwrap();
    assert!(
        super::copied_here(home.path(), &before, Some("box-b")),
        "a mismatch is a copy before any start"
    );
    assert_eq!(
        super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
        super::CloneCheck::Cloned
    );
    let record = super::load_at(home.path()).unwrap().unwrap();
    assert!(record.cloned);
    // Nothing of the original's enrollment changes: no hub call, the same credential and id.
    assert_eq!(record.credential, before.credential);
    assert_eq!(record.machine_id, before.machine_id);
    assert_eq!(record.host_fingerprint.as_deref(), Some("box-a"));
    let fresh = std::fs::read(home.path().join("node.wg.key")).unwrap();
    assert_ne!(fresh, key, "the copy has its own node key");
    // Sticky: the next start finds it cloned and keeps the new key.
    assert_eq!(
        super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
        super::CloneCheck::AlreadyCloned
    );
    assert_eq!(std::fs::read(home.path().join("node.wg.key")).unwrap(), fresh);
    assert!(
        super::copied_here(home.path(), &record, Some("box-b"))
            && super::copied_here(home.path(), &record, None)
    );
}

#[test]
#[cfg(unix)]
fn an_older_record_adopts_the_box_it_starts_on_and_no_identity_compares_nothing() {
    let home = tempfile::tempdir().unwrap();
    let key = joined_on(home.path(), None);
    let before = super::load_at(home.path()).unwrap().unwrap();
    assert!(!super::copied_here(home.path(), &before, Some("box-a")), "no fingerprint is no clone");
    assert_eq!(super::settle_clone_at(home.path(), None).unwrap(), super::CloneCheck::Unknown);
    assert_eq!(
        super::settle_clone_at(home.path(), Some("box-a")).unwrap(),
        super::CloneCheck::Adopted
    );
    let record = super::load_at(home.path()).unwrap().unwrap();
    assert_eq!(record.host_fingerprint.as_deref(), Some("box-a"));
    assert!(!record.cloned);
    assert_eq!(std::fs::read(home.path().join("node.wg.key")).unwrap(), key);
    assert_eq!(
        super::settle_clone_at(home.path(), Some("box-a")).unwrap(),
        super::CloneCheck::Same
    );
    // A box with no OS identity never marks a fingerprinted record cloned.
    let other = tempfile::tempdir().unwrap();
    joined_on(other.path(), Some("box-a"));
    assert_eq!(super::settle_clone_at(other.path(), None).unwrap(), super::CloneCheck::Unknown);
    assert!(!super::load_at(other.path()).unwrap().unwrap().cloned);
    let empty = tempfile::tempdir().unwrap();
    assert_eq!(
        super::settle_clone_at(empty.path(), Some("box-a")).unwrap(),
        super::CloneCheck::NotJoined
    );
}

#[test]
#[cfg(unix)]
fn an_instance_id_bound_after_the_join_is_the_same_box_not_a_clone() {
    use super::host_fingerprint::TEST_MACHINE_ONLY;
    let home = tempfile::tempdir().unwrap();
    // Joined on machine id "mid-a" before cmux-host bound an instance id.
    let key = joined_on(home.path(), Some("mid-a"));
    TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = Some(Some("mid-a".into())));
    let before = super::load_at(home.path()).unwrap().unwrap();
    assert!(!super::copied_here(home.path(), &before, Some("inst-1")));
    assert_eq!(
        super::settle_clone_at(home.path(), Some("inst-1")).unwrap(),
        super::CloneCheck::Adopted
    );
    let record = super::load_at(home.path()).unwrap().unwrap();
    assert_eq!(record.host_fingerprint.as_deref(), Some("inst-1"));
    assert!(!record.cloned);
    assert_eq!(std::fs::read(home.path().join("node.wg.key")).unwrap(), key);
    // A copy onto another box: another machine id, and a record bound to another instance.
    TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = Some(Some("mid-b".into())));
    assert_eq!(
        super::settle_clone_at(home.path(), Some("inst-2")).unwrap(),
        super::CloneCheck::Cloned
    );
    TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = None);
}

#[test]
#[cfg(unix)]
fn a_cloud_fork_still_on_the_originals_machine_id_is_a_clone() {
    use super::host_fingerprint::TEST_MACHINE_ONLY;
    // Joined on "mid-a" before a bind, then forked: the fork keeps machine id "mid-a" until
    // it is rekeyed, but cmux-host marked its home with `clone-boot` before this start.
    for marker in [crate::hub::clone_boot::MARKER, crate::hub::clone_boot::DONE] {
        let home = tempfile::tempdir().unwrap();
        let key = joined_on(home.path(), Some("mid-a"));
        std::fs::write(home.path().join(marker), r#"{"from":"m1","to":"m2"}"#).unwrap();
        TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = Some(Some("mid-a".into())));
        let before = super::load_at(home.path()).unwrap().unwrap();
        assert!(super::copied_here(home.path(), &before, Some("inst-2")), "{marker}");
        assert_eq!(
            super::settle_clone_at(home.path(), Some("inst-2")).unwrap(),
            super::CloneCheck::Cloned,
            "{marker}"
        );
        assert_ne!(std::fs::read(home.path().join("node.wg.key")).unwrap(), key);
        TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = None);
    }
}

#[test]
fn an_older_record_reads_unfingerprinted_and_not_cloned() {
    let old = serde_json::json!({"credential":"cmm_x","machine_id":"m","team_id":"t","name":"n",
            "hub_origin":"https://example.com","last_heartbeat":null,"revoked":false,"wgPublicKey":"k"});
    let record: super::MachineCredential = serde_json::from_value(old).unwrap();
    assert_eq!(record.host_fingerprint, None);
    assert!(!record.cloned);
    let written = serde_json::to_value(&record).unwrap();
    assert!(written.get("cloned").is_none() && written.get("host_fingerprint").is_none());
}

#[test]
fn a_join_grants_the_same_person_and_keeps_the_owners_own_entries() {
    use crate::mesh_http::{MeshControlFrom, MeshRelayConfig};
    assert_eq!(super::joined_control_from(None), vec![MeshControlFrom::same_user()]);
    let own =
        MeshControlFrom { daemon_id: "d1".into(), ops: vec!["stop".into()], ..Default::default() };
    let previous = MeshRelayConfig { control_from: vec![own.clone()], ..Default::default() };
    assert_eq!(super::joined_control_from(Some(previous)), vec![own, MeshControlFrom::same_user()]);
    // An owner who narrowed or emptied `sameUser` keeps that choice across a rejoin.
    let narrowed = MeshControlFrom { ops: vec![], ..MeshControlFrom::same_user() };
    let previous = MeshRelayConfig { control_from: vec![narrowed.clone()], ..Default::default() };
    assert_eq!(super::joined_control_from(Some(previous)), vec![narrowed]);
}

#[test]
fn an_older_record_reads_with_no_person_and_a_new_one_keeps_it() {
    let old = serde_json::json!({"credential":"cmm_x","machine_id":"m","team_id":"t","name":"n",
            "hub_origin":"https://example.com","last_heartbeat":null,"revoked":false,"wgPublicKey":"k"});
    let record: super::MachineCredential = serde_json::from_value(old).unwrap();
    assert_eq!(record.user_id, None);
    let record = super::MachineCredential { user_id: Some("user_1".into()), ..record };
    let round: super::MachineCredential =
        serde_json::from_value(serde_json::to_value(&record).unwrap()).unwrap();
    assert_eq!(round.user_id.as_deref(), Some("user_1"));
    assert_eq!(super::safe_id("user_1").as_deref(), Some("user_1"));
    for bad in ["", "cmm_secret", "a\nb"] {
        assert_eq!(super::safe_id(bad), None, "{bad:?}");
    }
}

#[test]
fn identity_projection_drops_the_bearer_credential() {
    let record = MachineCredential {
        credential: "do-not-leak-secret-value".into(),
        machine_id: "machine-1".into(),
        team_id: "team-1".into(),
        name: "cloud-machine".into(),
        hub_origin: "https://cmux.example".into(),
        last_heartbeat: None,
        revoked: false,
        wg_public_key: "public-key".into(),
        credential_generation: 1,
        user_id: None,
        host_fingerprint: None,
        cloned: false,
        joined_by: None,
        capabilities: None,
        cloned_on: None,
    };
    let identity = MachineIdentity::from_record(&record);
    let serialized = serde_json::to_string(&identity).unwrap();
    assert!(!serialized.contains(&record.credential));
    assert!(serialized.contains("machine-1"));
}

#[test]
#[cfg(unix)]
fn concurrent_join_is_refused_before_a_second_redeem() {
    let dir = tempfile::tempdir().unwrap();
    let first = super::join_lock_at(dir.path()).unwrap();
    assert!(super::join_lock_at(dir.path()).is_err());
    // A process spawned meanwhile holds a copy from its fork until its exec.
    let inherited = first.0.try_clone().unwrap();
    drop(first);
    assert!(super::join_lock_at(dir.path()).is_ok());
    drop(inherited);
}
