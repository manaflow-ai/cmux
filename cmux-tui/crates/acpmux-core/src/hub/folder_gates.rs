//! Release measurements for the folders serving paths (PR 5f).

use super::*;
use crate::wire::{
    Anchor, FolderPageResult, FolderPosition, FolderRow, FolderWindow, ListView, Page, PageSide,
    Position, Sub,
};
use acpmux_book::index::{RowKey, Summary};
use serde_json::value::RawValue;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 5;
const SAMPLES: usize = 200;

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    let index = ((values.len() * 95).saturating_add(99) / 100).saturating_sub(1);
    values.get(index).copied().unwrap_or(1)
}

fn best_p95(rounds: &[Vec<u128>]) -> u128 {
    rounds.iter().map(|round| p95(&mut round.clone())).min().unwrap_or(1)
}

fn pooled_p95(rounds: &[Vec<u128>]) -> u128 {
    p95(&mut rounds.iter().flatten().copied().collect::<Vec<_>>())
}

fn gate(name: &str, small: u128, god: u128, god_all: u128) {
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{god_all},\"unit\":\"ns\"}}"
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
}

fn row(id: usize, count: usize, folders: usize) -> Summary {
    let mut row = Summary::new(format!("chat-{id:04}"));
    row.last_activity = (10_000 + count - id) as u64;
    row.folder = Some(format!("/folder-{:04}", id % folders));
    row.extra = RawValue::from_string("{}".into()).unwrap_or_else(|_| RawValue::NULL.to_owned());
    row
}

fn fixture(count: usize) -> Hub {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let chats = if count == 5 { 20 } else { 11_000 };
    for id in 0..chats {
        assert!(writer.apply(row(id, chats, count)).is_ok(), "apply fixture row {id}");
    }
    assert_eq!(hub.snapshot().folders().len(), count);
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
    let mut page = Page::new("folders", "list", PageSide::After, 0);
    page.view = Some(ListView::Folders);
    page.max_bytes = folder_page_budget();
    page.after = Some(Position::Folder(FolderPosition {
        at: (10_000 + if count == 5 { 20 } else { 11_000 } - cursor) as u64,
        origin: "local".into(),
        folder: format!("/folder-{cursor:04}"),
    }));
    page
}

fn folder_page_budget() -> u32 {
    let row = FolderRow {
        origin: "local".into(),
        folder: "/folder-0000".into(),
        newest: RowKey::new("local", "chat-0000"),
        at: 10_000,
        count: 1,
    };
    let key = FolderPosition {
        at: row.at,
        origin: row.origin.to_string(),
        folder: row.folder.to_string(),
    };
    (8192
        + serde_json::to_vec("folders").unwrap().len()
        + 2 * serde_json::to_vec(&key).unwrap().len()
        + 3 * (row.encoded_len() + 1)) as u32
}

fn measure_window(hub: &Hub, request: &Sub) -> Vec<Vec<u128>> {
    (0..ROUNDS)
        .map(|_| {
            (0..SAMPLES)
                .map(|_| {
                    let start = Instant::now();
                    std::hint::black_box(
                        hub.list_window(request)
                            .unwrap_or_else(|error| panic!("folders window: {error}")),
                    );
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
                    std::hint::black_box(
                        hub.page(request).unwrap_or_else(|error| panic!("folders page: {error}")),
                    );
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
    let small_window: FolderWindow = small_hub
        .list_window(&request)
        .unwrap_or_else(|error| panic!("small folders window: {error}"))
        .decode_json()
        .unwrap_or_else(|error| panic!("small window JSON: {error}"));
    let god_window: FolderWindow = god_hub
        .list_window(&request)
        .unwrap_or_else(|error| panic!("god folders window: {error}"))
        .decode_json()
        .unwrap_or_else(|error| panic!("god window JSON: {error}"));
    assert_eq!(small_window.rows.len(), 3);
    assert_eq!(god_window.rows.len(), 3);
    assert!(small_window.has_after && god_window.has_after);
    let small_window = measure_window(&small_hub, &request);
    let god_window = measure_window(&god_hub, &request);
    let small = best_p95(&small_window);
    let god = best_p95(&god_window);
    let all_god = pooled_p95(&god_window);
    assert!(god <= small.saturating_mul(12) / 10, "window ratio {god}/{small}");
    assert!(all_god <= small.saturating_mul(2), "window pooled ratio {all_god}/{small}");
    gate("v2.pr05f.serving_window", small, god, all_god);

    let small_page = deep_request(5, 0);
    let god_page = deep_request(2_000, 999);
    let small_page_result: FolderPageResult = small_hub
        .page(&small_page)
        .unwrap_or_else(|error| panic!("small folders page: {error}"))
        .decode_json()
        .unwrap_or_else(|error| panic!("small page JSON: {error}"));
    let god_page_result: FolderPageResult = god_hub
        .page(&god_page)
        .unwrap_or_else(|error| panic!("god folders page: {error}"))
        .decode_json()
        .unwrap_or_else(|error| panic!("god page JSON: {error}"));
    assert_eq!(small_page_result.rows.len(), 3);
    assert_eq!(god_page_result.rows.len(), 3);
    assert!(small_page_result.has_after && god_page_result.has_after);
    let small_rounds = measure_page(&small_hub, &small_page);
    let god_rounds = measure_page(&god_hub, &god_page);
    let small = best_p95(&small_rounds);
    let god = best_p95(&god_rounds);
    let all_god = pooled_p95(&god_rounds);
    assert!(god <= small.saturating_mul(12) / 10, "page ratio {god}/{small}");
    assert!(all_god <= small.saturating_mul(2), "page pooled ratio {all_god}/{small}");
    gate("v2.pr05f.serving_page", small, god, all_god);
}
