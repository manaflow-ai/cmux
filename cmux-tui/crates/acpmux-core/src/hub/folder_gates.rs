//! Release measurements for the folders serving paths (PR 5f).

use super::*;
use crate::wire::{Anchor, FolderPosition, ListView, Page, Position, Sub};
use acpmux_book::index::Summary;
use serde_json::value::RawValue;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 5;
const SAMPLES: usize = 200;

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    values[((values.len() * 95).saturating_add(99) / 100).saturating_sub(1)]
}

fn best_p95(rounds: &[Vec<u128>]) -> u128 {
    rounds.iter().map(|round| p95(&mut round.clone())).min().unwrap_or(1)
}

fn pooled_p95(rounds: &[Vec<u128>]) -> u128 {
    p95(&mut rounds.iter().flatten().copied().collect::<Vec<_>>())
}

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

fn row(id: usize, count: usize) -> Summary {
    let mut row = Summary::new(format!("chat-{id:04}"));
    row.last_activity = (count - id) as u64;
    row.folder = Some(format!("/folder-{id:04}"));
    row.extra = RawValue::from_string("{}".into()).expect("literal JSON");
    row
}

fn fixture(count: usize) -> Hub {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    for id in 0..count {
        writer.apply(row(id, count)).expect("apply fixture row");
    }
    hub
}

fn window_request() -> Sub {
    let mut sub = Sub::new("folders", "list");
    sub.view = Some(ListView::Folders);
    sub.anchor = Some(Anchor::End);
    sub.window = Some(3);
    sub
}

fn deep_request(count: usize, cursor: usize) -> Page {
    let mut page = Page::new("folders", "list", crate::wire::PageSide::After, 0);
    page.view = Some(ListView::Folders);
    page.max_bytes = 32 * 1024;
    page.after = Some(Position::Folder(FolderPosition {
        at: (count - cursor) as u64,
        origin: "local".into(),
        folder: format!("/folder-{cursor:04}"),
    }));
    page
}

fn measure_window(hub: &Hub, request: &Sub) -> Vec<Vec<u128>> {
    (0..ROUNDS)
        .map(|_| {
            (0..SAMPLES)
                .map(|_| {
                    let start = Instant::now();
                    std::hint::black_box(hub.list_window(request).expect("folders window"));
                    start.elapsed().as_nanos()
                })
                .collect()
        })
        .collect()
}

fn measure_page(hub: &Hub, request: &Page) -> Vec<Vec<u128>> {
    (0..ROUNDS)
        .map(|_| {
            (0..SAMPLES)
                .map(|_| {
                    let start = Instant::now();
                    std::hint::black_box(hub.page(request).expect("folders page"));
                    start.elapsed().as_nanos()
                })
                .collect()
        })
        .collect()
}

#[test]
#[ignore = "release gate; run once through cmux-ci"]
fn folders_serving_release_gates() {
    let small_hub = fixture(5);
    let god_hub = fixture(2_000);
    let request = window_request();
    let small_window = measure_window(&small_hub, &request);
    let god_window = measure_window(&god_hub, &request);
    let small = best_p95(&small_window);
    let god = best_p95(&god_window);
    let all_small = pooled_p95(&small_window);
    let all_god = pooled_p95(&god_window);
    assert!(god <= small.saturating_mul(12) / 10, "window ratio {god}/{small}");
    assert!(all_god <= all_small.saturating_mul(2), "window pooled ratio {all_god}/{all_small}");
    gate("v2.pr05f.serving_window", small, god);

    let small_page = deep_request(5, 0);
    let god_page = deep_request(2_000, 999);
    let small_rounds = measure_page(&small_hub, &small_page);
    let god_rounds = measure_page(&god_hub, &god_page);
    let small = best_p95(&small_rounds);
    let god = best_p95(&god_rounds);
    let all_small = pooled_p95(&small_rounds);
    let all_god = pooled_p95(&god_rounds);
    assert!(god <= small.saturating_mul(12) / 10, "page ratio {god}/{small}");
    assert!(all_god <= all_small.saturating_mul(2), "page pooled ratio {all_god}/{all_small}");
    gate("v2.pr05f.serving_page", small, god);
}
