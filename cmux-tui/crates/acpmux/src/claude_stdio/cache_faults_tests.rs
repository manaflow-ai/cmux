//! Cache fault classes (`cache_faults.rs`, RFD 0182 B6).

use super::*;

const CTX: u64 = 100_000;

#[test]
fn a_first_call_or_a_small_context_is_new() {
    assert_eq!(classify(true, CTX, 0, "unknown"), Fault::New);
    assert_eq!(classify(false, 1_000, 0, "expired"), Fault::New);
}

#[test]
fn reading_half_the_context_is_a_hit() {
    assert_eq!(classify(false, CTX, CTX / 2, "expired"), Fault::Hit);
    assert_eq!(classify(false, CTX, CTX, "unknown"), Fault::Hit);
}

#[test]
fn misses_take_the_class_of_their_cause() {
    for cause in ["compaction", "model", "effort"] {
        assert_eq!(classify(false, CTX, 0, cause), Fault::Compulsory, "{cause}");
    }
    assert_eq!(classify(false, CTX, 0, "expired"), Fault::Capacity);
    assert_eq!(classify(false, CTX, 1_000, "unknown"), Fault::Conflict, "warm cache gone");
    assert_eq!(classify(false, CTX, 30_000, "unknown"), Fault::Churn, "part of the prefix read");
}

#[test]
fn counts_keep_misses_unread_tokens_and_gaps() {
    let mut counts = FaultCounts::default();
    assert_eq!(counts.to_json(), None, "nothing until a call");
    counts.record(Fault::New, 0, 0);
    counts.record(Fault::Hit, 0, 2_000);
    counts.record(Fault::Capacity, 90_000, 600_000);
    counts.record(Fault::Capacity, 80_000, 400_000);
    counts.record(Fault::Conflict, 70_000, 30_000);
    assert_eq!(counts.get(Fault::Capacity), 2);
    assert_eq!(counts.median_gap_ms(), Some(400_000), "hits and first calls log no gap");
    let out = counts.to_json().unwrap();
    assert_eq!(out["calls"]["hit"], 1);
    assert_eq!(out["calls"]["capacity"], 2);
    assert_eq!(out["unreadTokens"]["capacity"], 170_000);
    assert_eq!(out["unreadTokens"].get("hit"), None, "a hit rewrites nothing");
    assert_eq!(out["medianMissGapMs"], 400_000);
}

#[test]
fn the_gap_median_reads_only_the_newest_misses() {
    let mut counts = FaultCounts::default();
    for _ in 0..GAP_SAMPLES {
        counts.record(Fault::Churn, 1, 1);
    }
    for _ in 0..GAP_SAMPLES {
        counts.record(Fault::Capacity, 1, 900_000);
    }
    assert_eq!(counts.median_gap_ms(), Some(900_000));
    assert_eq!(counts.get(Fault::Churn), GAP_SAMPLES as u64, "counts keep every call");
}
