//! Release measurements for the bounded folders delta tail (PR 5f part three).
//!
//! Equal 100-step reads at 20 chats / 5 folders and 11k chats / 2k folders.
//! Fixtures, cursor repositioning and verification stay outside the clock.

use super::*;
use crate::wire::Sub;
use acpmux_book::index::Summary;
use serde_json::value::RawValue;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const TAIL_BYTES: usize = 64 * 1024;

fn gate(name: &str, small: u128, god: u128, all: u128) {
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{all},\"unit\":\"ns\"}}"
    );
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
    let index = ((values.len() * 95).saturating_add(99) / 100).saturating_sub(1);
    values.get(index).copied().unwrap_or(1)
}

fn pooled_p95(rounds: &[Vec<u128>]) -> u128 {
    p95(&mut rounds.iter().flatten().copied().collect::<Vec<_>>())
}

fn fixture(folders: usize, chats: usize) -> (Hub, ListSubscription) {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    for id in 0..chats {
        writer.apply(row(id, &format!("/folder-{:04}", id % folders), id as u64)).unwrap();
    }
    let subscription = hub.subscribe(&sub()).unwrap();
    for at in 20_000..20_100 {
        writer.apply(row(0, "/folder-0000", at)).unwrap();
    }
    let RawRead::Span(span) = subscription.receiver.try_next_raw(None, 256 * 1024).unwrap() else {
        panic!("100 retained steps must fit one frame")
    };
    let json = format!("[{}]", std::str::from_utf8(&span.bytes).unwrap());
    let ops: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap();
    assert_eq!(ops.len(), 100);
    assert_eq!(hub.snapshot().folders().len(), folders);
    assert!(hub.folder_state.lock().unwrap().retained_bytes() <= TAIL_BYTES);
    (hub, subscription)
}

fn sample(subscription: &ListSubscription) -> u128 {
    subscription.receiver.reposition(subscription.cursor);
    let start = Instant::now();
    let span = std::hint::black_box(subscription.receiver.try_next_raw(None, 256 * 1024));
    let elapsed = start.elapsed().as_nanos();
    assert!(matches!(span, Some(RawRead::Span(_))));
    elapsed
}

#[test]
#[ignore = "release gate; run once through cmux-ci"]
fn folders_tail_release_gates() {
    let (_small_hub, small_sub) = fixture(5, 20);
    let (_god_hub, god_sub) = fixture(2_000, 11_000);
    let mut small_rounds = Vec::new();
    let mut god_rounds = Vec::new();
    for _ in 0..5 {
        let mut small = Vec::new();
        let mut god = Vec::new();
        for n in 0..200 {
            // Alternate sides so a shared host's changing load affects both.
            if n % 2 == 0 {
                small.push(sample(&small_sub));
                god.push(sample(&god_sub));
            } else {
                god.push(sample(&god_sub));
                small.push(sample(&small_sub));
            }
        }
        small_rounds.push(small);
        god_rounds.push(god);
    }
    let small = small_rounds.iter().map(|r| p95(&mut r.clone())).min().unwrap();
    let god = god_rounds.iter().map(|r| p95(&mut r.clone())).min().unwrap();
    let all = pooled_p95(&god_rounds);
    gate("v2.pr05f.tail_replay", small, god, all);
    assert!(god <= small.saturating_mul(12) / 10, "tail ratio {god}/{small}");
    assert!(all <= small.saturating_mul(2), "tail pooled ratio {all}/{small}");
}
