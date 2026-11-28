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
