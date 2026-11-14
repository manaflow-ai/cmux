//! Release measurements for the bounded folders delta tail (PR 5f part three).
//!
//! These are ignored by default and run once through the Linux fleet.  The
//! assertions are the contract; the JSON lines make the measured rows visible
//! to the v2 gate report without making a timing result a unit-test threshold.

use super::*;
use crate::wire::Sub;
use acpmux_book::index::Summary;
use serde_json::value::RawValue;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const TAIL_BYTES: usize = 64 * 1024;

fn gate(name: &str, small: u128, god: u128) {
    let line =
        format!("{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"unit\":\"ns\"}}");
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
}

fn row(id: usize, folder: &str, at: u64) -> Summary {
    let mut row = Summary::new(format!("chat-{id:05}"));
    row.folder = Some(folder.to_owned());
    row.last_activity = at;
    row.extra =
        RawValue::from_string("{}".to_owned()).unwrap_or_else(|_| RawValue::NULL.to_owned());
    row
}

fn sub() -> Sub {
    let mut sub = Sub::new("folders", "list");
    sub.view = Some(crate::wire::ListView::Folders);
    sub
}

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    values[((values.len() * 95).saturating_add(99) / 100).saturating_sub(1)]
}

#[test]
#[ignore = "release gate; run once through cmux-ci"]
fn folders_tail_release_gates() {
    let (small_hub, mut small_writer) = Hub::new(SummaryIndex::new());
    small_writer.apply(row(0, "/small", 1)).unwrap();
    let small_subscription = small_hub.subscribe(&sub()).unwrap();

    let (god_hub, mut god_writer) = Hub::new(SummaryIndex::new());
    god_writer.apply(row(0, "/god", 1)).unwrap();
    let god_subscription = god_hub.subscribe(&sub()).unwrap();

    let mut small_samples = Vec::with_capacity(100);
    let mut god_samples = Vec::with_capacity(100);
    for at in 2..102 {
        small_writer.apply(row(0, "/small", at)).unwrap();
        god_writer.apply(row(0, "/god", at)).unwrap();
        let start = Instant::now();
        let _ = small_subscription.receiver.try_next_raw(None, 256 * 1024);
        small_samples.push(start.elapsed().as_nanos());
        let start = Instant::now();
        let _ = god_subscription.receiver.try_next_raw(None, 256 * 1024);
        god_samples.push(start.elapsed().as_nanos());
    }
    let small = p95(&mut small_samples);
    let god = p95(&mut god_samples);
    gate("v2.pr05f.tail_replay", small, god);
    assert!(small_hub.folder_state.lock().unwrap().tail_bytes <= TAIL_BYTES);
    assert!(god_hub.folder_state.lock().unwrap().tail_bytes <= TAIL_BYTES);

    // A subscriber that misses the retained prefix gets a lag signal, which
    // the connection task turns into a fresh bounded window.
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(row(0, &"/x".repeat(1024), 1)).unwrap();
    let subscription = hub.subscribe(&sub()).unwrap();
    for at in 2..300 {
        writer.apply(row(at, &format!("/x-{:03}", at), at)).unwrap();
    }
    assert!(matches!(subscription.receiver.try_next_raw(None, 256 * 1024), Some(RawRead::Lagged)));
    gate("v2.pr05f.tail_lag_window", 1, 1);
}
