use super::*;

/// A 4 MB chat is the calibration chat's shape: small records, hundreds a turn, its bytes
/// within a turn of those asked for, and `session.json` agreeing with the log.
#[test]
fn a_chat_is_many_small_records_and_its_meta_agrees() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("acpmux");
    let asked = 4 << 20;
    let w = write_chat(&home, &dir.path().join("work"), asked).unwrap();
    let per_record = w.bytes / w.records;
    assert!((250..=1200).contains(&per_record), "{per_record} bytes a record: {w:?}");
    let per_turn = w.records / w.turns;
    assert!((150..=2500).contains(&per_turn), "{per_turn} records a turn: {w:?}");
    assert!(w.bytes >= asked && w.bytes < asked + (8 << 20), "{w:?}");
    let on_disk: u64 = std::fs::read_dir(home.join("sessions").join(CHAT_ID).join("events"))
        .unwrap()
        .map(|e| e.unwrap().metadata().unwrap().len())
        .sum();
    assert_eq!(on_disk, w.bytes, "the counted bytes are the log's");
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, &home).unwrap();
    let meta = store.load(CHAT_ID).unwrap().unwrap();
    assert_eq!(meta.last_seq, w.last_seq);
    let mut prompts = 0;
    store
        .scan_kinds(CHAT_ID, &["user_message"], &mut |_| {
            prompts += 1;
            true
        })
        .unwrap();
    assert_eq!(prompts, w.turns);
}

#[test]
fn the_same_size_is_the_same_chat() {
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let wa = write_chat(&a.path().join("h"), &a.path().join("w"), 1 << 20).unwrap();
    let wb = write_chat(&b.path().join("h"), &b.path().join("w"), 1 << 20).unwrap();
    assert_eq!((wa.bytes, wa.records, wa.turns), (wb.bytes, wb.records, wb.turns));
}
