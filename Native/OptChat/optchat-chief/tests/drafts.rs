//! The reply streams to every client as drafts (parity item 4): while a
//! turn runs, the brain publishes its reply text per segment (a new segment
//! after each tool call), numbered 1, 2, 3 ..., and ends with a `done`
//! draft. Applying the drafts in order gives each segment's text; the last
//! segment is the posted reply.

mod common;

use std::collections::BTreeMap;

use common::*;
use optchat_chief::draft::Draft;

/// What a client shows: each segment's text after applying `drafts`.
fn apply(drafts: &[Draft]) -> BTreeMap<u64, String> {
    let mut segments: BTreeMap<u64, String> = BTreeMap::new();
    for d in drafts.iter().filter(|d| !d.done) {
        let text = segments.entry(d.segment).or_default();
        if d.fresh {
            *text = d.text.clone();
        } else {
            text.push_str(&d.text);
        }
    }
    segments
}

#[test]
fn a_turn_streams_its_reply_as_drafts() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hi");
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    let (key, reply) = sends.last().unwrap().clone();
    let drafts: Vec<(String, Draft)> = h.owner.lock().unwrap().drafts.clone();
    assert!(!drafts.is_empty(), "no drafts");
    assert!(drafts.iter().all(|(c, _)| c == CONV), "{drafts:?}");
    let drafts: Vec<Draft> = drafts.into_iter().map(|(_, d)| d).collect();
    assert!(drafts.iter().all(|d| d.turn == key), "{drafts:?}");
    let seqs: Vec<u64> = drafts.iter().map(|d| d.seq).collect();
    assert_eq!(seqs, (1..=drafts.len() as u64).collect::<Vec<_>>());
    assert!(drafts.last().unwrap().done, "{drafts:?}");
    assert_eq!(drafts.iter().filter(|d| d.done).count(), 1);
    let segments = apply(&drafts);
    assert_eq!(segments.get(&0).map(String::as_str), Some("Checking."));
    assert_eq!(segments.get(&1).map(String::as_str), Some(reply.as_str()));
}
