use super::{BOUND_MS, Ended, LEADS_MAX, Ledger, PEERS_MAX};

/// The first keystroke opens a wake, later ones of the draft do not, and the send ends it with
/// the lead from the first keystroke.
#[test]
fn a_sent_draft_counts_its_lead_from_the_first_keystroke() {
    let mut l = Ledger::default();
    assert!(l.composing("vm-1", 1_000));
    assert!(!l.composing("vm-1", 4_000));
    assert_eq!(l.sent("vm-1", 9_500), Some(Ended::Sent { lead_ms: 8_500 }));
    // A second send with no typing in between is no typing wake.
    assert_eq!(l.sent("vm-1", 9_600), None);
    let s = l.json(10_000);
    assert_eq!(
        (s["opened"].as_u64(), s["sent"].as_u64(), s["unsent"].as_u64()),
        (Some(1), Some(1), Some(0))
    );
    assert_eq!(s["leadMs"]["p50"].as_u64(), Some(8_500));
    assert_eq!(s["unsentShare"].as_f64(), Some(0.0));
}

/// A draft with no send within the bound is thrown away, read by the next call; a send after
/// that ends nothing, and the next keystroke opens a new wake.
#[test]
fn a_draft_past_the_bound_is_unsent() {
    let mut l = Ledger::default();
    assert!(l.composing("vm-1", 0));
    assert_eq!(l.json(BOUND_MS - 1)["open"].as_u64(), Some(1));
    let s = l.json(BOUND_MS);
    assert_eq!((s["open"].as_u64(), s["unsent"].as_u64()), (Some(0), Some(1)));
    assert_eq!(l.sent("vm-1", BOUND_MS + 5), None);
    assert!(l.composing("vm-1", BOUND_MS + 10));
    assert_eq!(l.sent("vm-1", BOUND_MS + 20), Some(Ended::Sent { lead_ms: 10 }));
    let s = l.json(BOUND_MS + 30);
    assert_eq!(s["unsentShare"].as_f64(), Some(0.5));
}

/// Peers are counted apart: a send to one never ends another's wake.
#[test]
fn peers_are_apart() {
    let mut l = Ledger::default();
    l.composing("vm-1", 0);
    l.composing("vm-2", 0);
    assert_eq!(l.sent("vm-2", 100), Some(Ended::Sent { lead_ms: 100 }));
    assert_eq!(l.json(200)["open"].as_u64(), Some(1));
}

/// Bounded: past `PEERS_MAX` open wakes the oldest is closed as unsent, and only the last
/// `LEADS_MAX` leads are kept.
#[test]
fn it_stays_bounded() {
    let mut l = Ledger::default();
    for i in 0..=PEERS_MAX as u64 {
        l.composing(&format!("vm-{i}"), i);
    }
    let s = l.json(PEERS_MAX as u64 + 1);
    assert_eq!((s["open"].as_u64(), s["unsent"].as_u64()), (Some(PEERS_MAX as u64), Some(1)));
    let mut l = Ledger::default();
    for i in 0..(LEADS_MAX as u64 + 10) {
        l.composing("vm", i * 10);
        l.sent("vm", i * 10 + i);
    }
    let s = l.json(1_000_000);
    assert_eq!(s["leadMs"]["n"].as_u64(), Some(LEADS_MAX as u64));
    assert_eq!(s["leadMs"]["max"].as_u64(), Some(LEADS_MAX as u64 + 9));
}

/// No wake yet: the quantiles and share are null, not zero.
#[test]
fn empty_is_null() {
    let s = Ledger::default().json(0);
    assert!(s["unsentShare"].is_null());
    assert!(s["leadMs"]["p50"].is_null());
}
