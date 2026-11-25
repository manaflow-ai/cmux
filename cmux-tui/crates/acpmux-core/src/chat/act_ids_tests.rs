use super::*;

#[test]
fn replay_and_id_reuse() {
    let home = tempfile::tempdir().unwrap();
    let mut ring = ActIdRing::empty(home.path());
    ring.remember("id", "append", &serde_json::json!({"text":"one"}), 41).unwrap();
    assert_eq!(
        ring.lookup("id", "append", &serde_json::json!({"text":"one"})),
        ActIdLookup::Replay { ack_seq: 41 }
    );
    assert_eq!(
        ring.lookup("id", "append", &serde_json::json!({"text":"two"})),
        ActIdLookup::IdReuse
    );
}

#[test]
fn floor_is_set_only_after_eviction_and_is_inclusive() {
    let home = tempfile::tempdir().unwrap();
    let mut ring = ActIdRing::empty(home.path());
    assert_eq!(ring.floor(), None);
    for seq in 0..=ACT_ID_CAPACITY {
        ring.remember(&format!("id-{seq}"), "op", &serde_json::json!(seq), seq as u64).unwrap();
    }
    assert_eq!(ring.floor(), Some(0));
    assert_eq!(
        ring.lookup_with_since("new-id", "op", &serde_json::json!(0), Some(0)),
        ActIdLookup::IdUnknown
    );
    assert_eq!(
        ring.lookup_with_since("new-id", "op", &serde_json::json!(0), Some(1)),
        ActIdLookup::New
    );
}

#[test]
fn missing_or_damaged_file_uses_checkpoint_floor() {
    let home = tempfile::tempdir().unwrap();
    let ring = ActIdRing::open_at(home.path(), 9).unwrap();
    assert_eq!(ring.floor(), Some(9));
    assert_eq!(
        ring.lookup_with_since("id", "op", &serde_json::json!(0), Some(9)),
        ActIdLookup::IdUnknown
    );
    fs::write(home.path().join(ACT_IDS_FILE), b"short").unwrap();
    let ring = ActIdRing::open_at(home.path(), 12).unwrap();
    assert_eq!(ring.floor(), Some(12));
}

#[test]
fn save_filters_uncheckpointed_tail_and_reopens() {
    let home = tempfile::tempdir().unwrap();
    let mut ring = ActIdRing::empty(home.path());
    ring.remember("old", "op", &serde_json::json!(true), 9).unwrap();
    ring.remember("tail", "op", &serde_json::json!(true), 10).unwrap();
    ring.save(9).unwrap();
    let ring = ActIdRing::open_at(home.path(), 9).unwrap();
    assert_eq!(ring.through(), 9);
    assert_eq!(
        ring.lookup("old", "op", &serde_json::json!(true)),
        ActIdLookup::Replay { ack_seq: 9 }
    );
    assert_eq!(ring.lookup("tail", "op", &serde_json::json!(true)), ActIdLookup::New);
}
