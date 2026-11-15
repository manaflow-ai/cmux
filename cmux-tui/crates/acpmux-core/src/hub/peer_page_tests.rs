//! A peer's `all` page reads at most PEER_PAGE_PIECES pieces (decision 285), and past them
//! answers empty with a `local` position, never another origin's row.

use super::*;
use crate::wire::{ListFilter, ListView, Page, PageResult};
use serde_json::Value;

const LOCAL: u64 = 11_020;
const RUN: u64 = 900;

/// 11,020 rows of this machine (the first 20 live), one in 1,000 in workspace `w`. Rows of
/// `c-machine` (before `local` in the order) and `z-machine` (after it) come now and then,
/// and two runs of 900 share one activity time each: `c-machine`'s after local row 100 and
/// `z-machine`'s after local row 5,000. Each run is longer than PEER_PAGE_PIECES pieces'
/// worth of rows of nothing else.
fn hub() -> (Hub, Vec<String>, Vec<String>) {
    let mut index = SummaryIndex::new();
    let (mut seq, mut local, mut in_w) = (0, Vec::new(), Vec::new());
    let mut add = |index: SummaryIndex, summary: Summary| {
        seq += 1;
        index.apply(seq, summary)
    };
    for n in 0..LOCAL {
        let mut mine = Summary::new(format!("b-{n:05}"));
        mine.last_activity = 1_000_000 - 2 * n;
        if n >= 20 {
            mine.state = "closed".into();
        }
        if n % 1_000 == 7 {
            mine.workspace = Some("w".into());
            in_w.push(mine.chat_id.clone());
        }
        local.push(mine.chat_id.clone());
        index = add(index, mine);
        let (origin, run) = match n {
            100 => ("c-machine", RUN),
            5_000 => ("z-machine", RUN),
            _ if n % 50 == 0 => ("c-machine", 1),
            _ if n % 50 == 25 => ("z-machine", 1),
            _ => continue,
        };
        for m in 0..run {
            let mut theirs = Summary::new(format!("{}-{n:05}-{m:03}", &origin[..1]));
            theirs.origin = origin.into();
            theirs.last_activity = 1_000_000 - 2 * n - 1;
            index = add(index, theirs);
        }
    }
    let (hub, _writer) = Hub::new(index);
    (hub, local, in_w)
}

fn all_page(filter: Option<ListFilter>) -> Page {
    let mut page = Page::new("pages", "list", PageSide::After, 0);
    page.after = None;
    page.view = Some(ListView::All);
    page.filter = filter;
    page
}

/// One page and the pieces it read. No frame names another machine or its rows.
fn read(hub: &Hub, page: &Page) -> (PageResult<Value>, usize) {
    PEER_PIECES.with(|read| read.set(0));
    let frame = hub.peer_page(page).expect("a peer's all page");
    let pieces = PEER_PIECES.with(|read| read.get());
    let text = std::str::from_utf8(frame.payload()).unwrap();
    assert!(!text.contains("c-machine") && !text.contains("z-machine"), "{text}");
    assert!(!text.contains("\"c-") && !text.contains("\"z-"), "another machine's row: {text}");
    (frame.decode_json().unwrap(), pieces)
}

/// The whole `after` walk: its rows, its pages, and the most pieces one page read.
fn walk(hub: &Hub, filter: Option<ListFilter>) -> (Vec<String>, usize, usize) {
    let mut page = all_page(filter);
    let (mut seen, mut pages, mut most) = (Vec::new(), 0, 0);
    loop {
        let (result, pieces) = read(hub, &page);
        pages += 1;
        most = most.max(pieces);
        assert!(pages < 1_000, "the walk does not end");
        for row in &result.rows {
            seen.push(row["chatId"].as_str().unwrap().to_owned());
        }
        if !result.has_after {
            break;
        }
        let key = result.after_key.expect("has_after with no key");
        assert_eq!(key.origin, "local", "a key names a local position");
        page.after = Some(Position::List(key));
    }
    (seen, pages, most)
}

#[test]
fn a_filter_that_matches_nothing_reads_at_most_four_pieces_a_page() {
    let (hub, _, _) = hub();
    let nowhere = ListFilter { workspace: Some("nowhere".into()), ..ListFilter::default() };
    let (result, pieces) = read(&hub, &all_page(Some(nowhere.clone())));
    assert_eq!(pieces, PEER_PAGE_PIECES, "the first page stops at the cap");
    assert!(result.rows.is_empty() && result.has_after, "empty, with more to follow");
    let (seen, pages, most) = walk(&hub, Some(nowhere));
    assert!(seen.is_empty());
    assert_eq!(most, PEER_PAGE_PIECES, "no page reads past the cap");
    // 12,020 or so candidates of 1,600 a page: the walk is a handful of pages, not one.
    assert!((7..=12).contains(&pages), "{pages} pages");
}

#[test]
fn the_capped_walk_returns_exactly_the_matching_local_rows() {
    let (hub, _, in_w) = hub();
    let w = ListFilter { workspace: Some("w".into()), ..ListFilter::default() };
    let (seen, _, most) = walk(&hub, Some(w));
    assert_eq!(seen, in_w, "each matching local row, newest first, once");
    assert!(most <= PEER_PAGE_PIECES);
}

#[test]
fn the_unfiltered_walk_is_every_local_row_past_both_runs() {
    let (hub, local, _) = hub();
    let (seen, _, most) = walk(&hub, None);
    assert_eq!(seen, local, "this machine's rows, newest first, each once");
    assert!(most <= PEER_PAGE_PIECES);
}
