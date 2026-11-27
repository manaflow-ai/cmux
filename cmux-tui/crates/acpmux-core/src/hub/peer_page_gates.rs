//! Ignored release measurement for a peer's `all` page (decision 266): the serving side's
//! read of this machine's rows, newest and deep, with 11,000 closed rows beside 20 live
//! against 20 closed, both behind a third machine's run of rows the page skips.

use super::*;
use crate::wire::{ListKey, ListView, Page, PageResult};
use serde_json::Value;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 10;
const SAMPLES: usize = 200;
const LIVE: u64 = 20;
const ROWS: usize = 20;
const THIRD: u64 = 500;

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    let rank = (values.len() * 95).div_ceil(100).saturating_sub(1);
    values.get(rank).copied().unwrap_or(1)
}

fn row(origin: &str, id: String, activity: u64, closed: bool) -> Summary {
    let mut summary = Summary::new(id);
    summary.origin = origin.to_owned();
    summary.state = if closed { "closed" } else { "running" }.to_owned();
    summary.title = "a row of fixed width".to_owned();
    summary.last_activity = activity;
    summary
}

/// 20 live rows of this machine, then a third machine's run of 500, then `closed` closed
/// rows of this machine, newest first. The pages: the newest, and the deepest full one.
fn fixture(closed: u64) -> (Hub, Page, Page) {
    let mut index = SummaryIndex::new();
    let mut seq = 0;
    let mut at = 1_000_000_000;
    let mut add = |index: SummaryIndex, summary: Summary| {
        seq += 1;
        index.apply(seq, summary)
    };
    let key = |at: u64, n: u64| ListKey {
        last_activity: at,
        chat_id: format!("b-{n:06}"),
        origin: "local".into(),
    };
    for n in 0..LIVE {
        at -= 1;
        index = add(index, row("local", format!("b-{n:06}"), at, false));
    }
    let mut last_local = key(at, LIVE - 1);
    for n in 0..THIRD {
        at -= 1;
        index = add(index, row("c-machine", format!("c-{n:06}"), at, false));
    }
    // The deepest full page is after the local row just before the last 20.
    let mut deep = None;
    for n in 0..closed {
        if n + ROWS as u64 == closed {
            deep = Some(last_local.clone());
        }
        at -= 1;
        index = add(index, row("local", format!("b-{:06}", LIVE + n), at, true));
        last_local = key(at, LIVE + n);
    }
    let row_bytes = index.get("b-000000").expect("a local row").encoded_len() + 1;
    let (hub, _writer) = Hub::new(index);
    let mut newest = Page::new("serve-gate", "list", PageSide::After, 0);
    newest.after = None;
    newest.view = Some(ListView::All);
    newest.max_bytes = u32::try_from(8192 + newest.sid.len() + ROWS * row_bytes).unwrap();
    let mut deepest = newest.clone();
    deepest.after = Some(Position::List(deep.expect("closed rows past one page")));
    (hub, newest, deepest)
}

fn sample(hub: &Hub, page: &Page) -> u128 {
    let started = Instant::now();
    let frame = hub.peer_page(page).expect("a peer's all page");
    let elapsed = started.elapsed().as_nanos();
    let result: PageResult<Value> = frame.decode_json().expect("a page");
    assert_eq!(result.rows.len(), ROWS, "equal rows on both sides");
    elapsed
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr08b_serve_page() {
    let (small, small_newest, small_deep) = fixture(ROWS as u64);
    let (god, god_newest, god_deep) = fixture(11_000);
    let mut lines = Vec::new();
    for (part, small_page, god_page) in
        [("newest", &small_newest, &god_newest), ("deep", &small_deep, &god_deep)]
    {
        let (mut small_rounds, mut god_rounds) = (Vec::new(), Vec::new());
        for _ in 0..ROUNDS {
            // Rounds alternate so a noisy stretch of the machine hits both sides.
            let mut samples: Vec<u128> = (0..SAMPLES).map(|_| sample(&small, small_page)).collect();
            small_rounds.push(p95(&mut samples));
            let mut samples: Vec<u128> = (0..SAMPLES).map(|_| sample(&god, god_page)).collect();
            god_rounds.push(p95(&mut samples));
        }
        let small_p95 = small_rounds.into_iter().min().unwrap_or(1);
        let god_p95 = god_rounds.into_iter().min().unwrap_or(1);
        lines.push((part, small_p95, god_p95));
    }
    let [(_, newest_small, newest_god), (_, deep_small, deep_god)] = lines[..] else {
        unreachable!("two parts")
    };
    let line = format!(
        "{{\"name\":\"v2.pr08b.serve_page\",\"small_p95\":{},\"god_p95\":{},\"newest_small\":{newest_small},\"newest_god\":{newest_god},\"deep_small\":{deep_small},\"deep_god\":{deep_god},\"rows\":{ROWS},\"unit\":\"ns\"}}",
        newest_small.max(deep_small),
        newest_god.max(deep_god),
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
    for (part, small_p95, god_p95) in lines {
        assert!(god_p95 * 10 <= small_p95 * 12, "{part} page p95: {small_p95} -> {god_p95} ns");
    }
}
