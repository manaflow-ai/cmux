use super::*;

#[test]
fn an_undecided_move_reads_as_a_line_that_offers_the_chat_back_once_offered() {
    assert_eq!(move_undecided_line(&json!({"moveUndecided": null}), 0), None);
    let asking = json!({"sessionId": "s1",
                        "moveUndecided": {"transferId": "t", "since": 1_000, "offeredAt": null}});
    let line = move_undecided_line(&asking, 121_000).unwrap();
    assert!(line.contains("still asking") && !line.contains("take-back"), "{line}");
    let offered = json!({"sessionId": "s1",
                         "moveUndecided": {"transferId": "t", "since": 1_000, "offeredAt": 600_000}});
    let line = move_undecided_line(&offered, 601_000).unwrap();
    assert!(line.contains("--abort --take-back s1"), "{line}");
}

#[test]
fn progress_reads_as_a_line() {
    let r = json!({"phase": "pre-copy", "round": 1, "totalBytes": 6_800_000_000u64,
                   "doneBytes": 120_300_000u64, "wireBytes": 12_100_000u64,
                   "bytesPerSec": 1_000_000u64, "etaSecs": 6720u64,
                   "target": "lane-vm-7"});
    assert_eq!(
        progress_text(&r),
        "pre-copy round 1 to lane-vm-7: 120.3 MB of 6.80 GB (wire 12.1 MB, 1.0 MB/s), \
             about 1h 52m left"
    );
    assert_eq!(move_progress_line(&json!({"moveProgress": null})), None);
    assert!(move_progress_line(&json!({"moveProgress": r})).unwrap().starts_with("move:"));
    assert_eq!(duration_text(9.0), "9s");
    assert_eq!(duration_text(843.0), "14m 03s");
}

#[test]
fn a_learned_level_reads_on_the_move_line() {
    let r = json!({"phase": "pre-copy", "round": 1, "totalBytes": 40_000_000u64,
                   "doneBytes": 4_000_000u64, "wireBytes": 400_000u64, "zstdLevel": 12u64,
                   "zstdLearned": 12u64, "linkClass": "ssh:lane-vm-7"});
    let line = progress_text(&r);
    assert!(line.contains("zstd 12 (learned 12 on ssh:lane-vm-7)"), "{line}");
    let fresh = json!({"phase": "pre-copy", "round": 1, "zstdLevel": 3u64});
    assert!(!progress_text(&fresh).contains("learned"));
}

#[test]
fn each_link_class_keeps_what_it_learned_and_a_new_one_takes_its_kinds_latest() {
    use cmux_bytes::serial::Learned;
    use move_levels::{class_of, kept_in, recall_in};
    let ssh = Reach::Ssh { host: "lane-vm-7".into(), socket: "/s".into() };
    assert_eq!(class_of(Some(&ssh)), ("ssh:lane-vm-7".to_owned(), "ssh"));
    let local = Reach::Socket { path: "/tmp/x.sock".into() };
    assert_eq!(class_of(Some(&local)), ("local".to_owned(), "local"));
    assert_eq!(class_of(None).1, "local");

    let relay = Learned { level: 12, link: 96e3, cpu: 1.0 };
    let lan = Learned { level: 1, link: 125e6, cpu: 0.8 };
    // Nothing kept, or a store that is not one: nothing recalled.
    assert_eq!(recall_in(&json!({}), "ssh:a", "ssh"), None);
    assert_eq!(recall_in(&json!([1]), "ssh:a", "ssh"), None);
    let store = kept_in(json!("garbage"), "ssh:relay", "ssh", relay, 1);
    let store = kept_in(store, "local", "local", lan, 2);
    let at = |s: &Value, c, k| recall_in(s, c, k).map(|l| l.level);
    assert_eq!(at(&store, "ssh:relay", "ssh"), Some(12));
    assert_eq!(at(&store, "local", "local"), Some(1));
    // An ssh host never seen starts from the last ssh host's, not from local's.
    assert_eq!(at(&store, "ssh:new", "ssh"), Some(12));
    // A second copy over the same class replaces its level and counts.
    let store = kept_in(store, "ssh:relay", "ssh", Learned { level: 9, ..relay }, 3);
    assert_eq!(at(&store, "ssh:relay", "ssh"), Some(9));
    assert_eq!(store["classes"]["ssh:relay"]["copies"], json!(2));
    // A kept level out of range is not recalled.
    let mut bad = store.clone();
    bad["classes"]["local"]["level"] = json!(40);
    bad["latest"]["local"]["level"] = json!(0);
    assert_eq!(at(&bad, "local", "local"), None);
}

#[test]
fn the_store_keeps_at_most_its_bound_of_classes_dropping_the_oldest() {
    use cmux_bytes::serial::Learned;
    let l = Learned { level: 9, link: 1e6, cpu: 1.0 };
    let mut store = json!({});
    for i in 0..80u64 {
        store = move_levels::kept_in(store, &format!("ssh:h{i}"), "ssh", l, i);
    }
    let classes = store["classes"].as_object().unwrap();
    assert_eq!(classes.len(), 64);
    assert!(!classes.contains_key("ssh:h0") && classes.contains_key("ssh:h79"));
}
