//! A peer's `all` page reads at most PEER_PAGE_PIECES pieces (decision 285), and past them
//! answers empty with a `local` position, never another origin's row. On side `before` that
//! position is a `past` key (decision 290), which no other door takes.

use super::*;
use crate::wire::{Anchor, AnchorSide, ListFilter, ListKey, ListView, Page, PageKey, PageResult};
use serde_json::Value;

/// More rows than PEER_PAGE_PIECES pieces hold, at one activity time.
const RUN: u64 = 1_700;

/// Activity times that hold a run of `c-machine` rows (before `local` in the order) and of
/// `z-machine` rows (after it), with local rows between them or none: the newest time there
/// is, the oldest, and two in between.
const RUNS: [(u64, u64); 4] = [(u64::MAX, 2), (700, 0), (500, 2), (0, 2)];

/// Local rows (some closed, one in nine in workspace `w`) spread over 1,000 to 1,400 and
/// 100 to 300, single rows of either other machine among them, and the runs of [`RUNS`].
/// Answers the hub, this machine's chat ids in the keys' order (newest first), and those of
/// them in workspace `w`.
fn hub() -> (Hub, Vec<String>, Vec<String>) {
    let mut rows: Vec<(u64, &str, String)> = Vec::new();
    for n in 0..200u64 {
        rows.push((1_400 - 2 * n, "local", format!("b-{n:05}")));
        if n % 10 == 0 {
            rows.push((1_399 - 2 * n, "c-machine", format!("c-{n:05}")));
            rows.push((1_399 - 2 * n, "z-machine", format!("z-{n:05}")));
        }
    }
    for n in 0..100u64 {
        rows.push((300 - 2 * n, "local", format!("b-{:05}", 200 + n)));
    }
    for (at, locals) in RUNS {
        for m in 0..RUN {
            rows.push((at, "c-machine", format!("c-{at}-{m:04}")));
            rows.push((at, "z-machine", format!("z-{at}-{m:04}")));
        }
        for m in 0..locals {
            rows.push((at, "local", format!("b-{at}-{m}")));
        }
    }
    let mut index = SummaryIndex::new();
    let mut local = Vec::new();
    for (seq, (at, origin, id)) in rows.into_iter().enumerate() {
        let mut summary = Summary::new(id);
        summary.origin = origin.to_owned();
        summary.last_activity = at;
        if origin == "local" {
            let n = local.len();
            if n >= 20 {
                summary.state = "closed".into();
            }
            if n % 9 == 4 {
                summary.workspace = Some("w".into());
            }
            local.push((SortKey::of(&summary), summary.chat_id.clone(), n % 9 == 4));
        }
        index = index.apply(seq as u64 + 1, summary);
    }
    local.sort();
    let in_w = local.iter().filter(|(_, _, w)| *w).map(|(_, id, _)| id.clone()).collect();
    let local = local.into_iter().map(|(_, id, _)| id).collect();
    let (hub, _writer) = Hub::new(index);
    (hub, local, in_w)
}

fn all_page(side: PageSide, from: Option<ListKey>, filter: Option<ListFilter>) -> Page {
    let mut page = Page::new("pages", "list", side, 0);
    page.after = None;
    page.before = None;
    match side {
        PageSide::Before => page.before = from.map(Position::List),
        PageSide::After => page.after = from.map(Position::List),
    }
    page.view = Some(ListView::All);
    page.filter = filter;
    page
}

fn past(at: u64) -> ListKey {
    ListKey { last_activity: at, chat_id: String::new(), origin: "local".into(), past: true }
}

/// One page and the pieces it read. No frame names another machine or its rows, and every
/// key it carries is `local`.
fn read(hub: &Hub, page: &Page) -> (PageResult<Value>, usize) {
    PEER_PIECES.with(|read| read.set((0, 0)));
    let frame = hub.peer_page(page).expect("a peer's all page");
    let (pieces, _) = PEER_PIECES.with(|read| read.get());
    let text = std::str::from_utf8(frame.payload()).unwrap();
    assert!(!text.contains("c-machine") && !text.contains("z-machine"), "{text}");
    assert!(!text.contains("\"c-") && !text.contains("\"z-"), "another machine's row: {text}");
    let result: PageResult<Value> = frame.decode_json().unwrap();
    for key in result.before_key.iter().chain(&result.after_key) {
        assert_eq!(key.origin, "local", "a key names a local position: {key:?}");
    }
    (result, pieces)
}

/// The whole walk on `side` from `from`: its rows in the keys' order, its pages, and the
/// most pieces one page read.
fn walk(
    hub: &Hub,
    side: PageSide,
    from: Option<ListKey>,
    filter: Option<ListFilter>,
) -> (Vec<String>, usize, usize) {
    walk_page(hub, side, all_page(side, from, filter))
}

/// [`walk`] from a page already built, with its own byte budget.
fn walk_page(hub: &Hub, side: PageSide, mut page: Page) -> (Vec<String>, usize, usize) {
    let (mut pages_rows, mut pages, mut most) = (Vec::<Vec<String>>::new(), 0, 0);
    loop {
        let (result, pieces) = read(hub, &page);
        pages += 1;
        most = most.max(pieces);
        assert!(pages < 1_000, "the walk does not end");
        pages_rows.push(
            result.rows.iter().map(|row| row["chatId"].as_str().unwrap().to_owned()).collect(),
        );
        let (more, key) = match side {
            PageSide::Before => (result.has_before, result.before_key),
            PageSide::After => (result.has_after, result.after_key),
        };
        if !more {
            break;
        }
        let key = key.expect("more with no key");
        match side {
            PageSide::Before => page.before = Some(Position::List(key)),
            PageSide::After => page.after = Some(Position::List(key)),
        }
    }
    // A `before` walk goes to newer keys page by page; each page is in the keys' order.
    if side == PageSide::Before {
        pages_rows.reverse();
    }
    (pages_rows.into_iter().flatten().collect(), pages, most)
}

#[test]
fn the_after_walk_is_every_local_row_once_past_runs_longer_than_the_cap() {
    let (hub, local, _) = hub();
    let (seen, _, most) = walk(&hub, PageSide::After, None, None);
    assert_eq!(seen, local, "this machine's rows, newest first, each once, and the walk ends");
    assert_eq!(most, PEER_PAGE_PIECES, "the runs reach the cap, and no page reads past it");
}

#[test]
fn the_before_walk_is_every_local_row_once_past_runs_longer_than_the_cap() {
    let (hub, local, _) = hub();
    // From the oldest position there is: past every local key at activity time 0.
    let (seen, _, most) = walk(&hub, PageSide::Before, Some(past(0)), None);
    assert_eq!(seen, local, "this machine's rows, each once, and the walk ends at u64::MAX");
    assert_eq!(most, PEER_PAGE_PIECES, "the runs reach the cap, and no page reads past it");
}

#[test]
fn a_filter_that_matches_nothing_reads_at_most_four_pieces_a_page() {
    let (hub, _, _) = hub();
    let nowhere = ListFilter { workspace: Some("nowhere".into()), ..ListFilter::default() };
    let (result, pieces) = read(&hub, &all_page(PageSide::After, None, Some(nowhere.clone())));
    assert_eq!(pieces, PEER_PAGE_PIECES, "the first page stops at the cap");
    assert!(result.rows.is_empty() && result.has_after, "empty, with more to follow");
    for (side, from) in [(PageSide::After, None), (PageSide::Before, Some(past(0)))] {
        let (seen, pages, most) = walk(&hub, side, from, Some(nowhere.clone()));
        assert!(seen.is_empty(), "{side:?}");
        assert_eq!(most, PEER_PAGE_PIECES, "{side:?}: no page reads past the cap");
        assert!(pages > 2, "{side:?}: {pages} pages");
    }
}

#[test]
fn the_capped_walk_returns_exactly_the_matching_local_rows() {
    let (hub, _, in_w) = hub();
    let w = ListFilter { workspace: Some("w".into()), ..ListFilter::default() };
    for (side, from) in [(PageSide::After, None), (PageSide::Before, Some(past(0)))] {
        let (seen, _, most) = walk(&hub, side, from, Some(w.clone()));
        assert_eq!(seen, in_w, "{side:?}: each matching local row, once");
        assert!(most <= PEER_PAGE_PIECES);
    }
}

#[test]
fn the_resume_key_is_a_local_position_past_the_last_candidate() {
    let key = |at: u64, origin: &str| SortKey { last_activity: at, row: RowKey::new(origin, "x") };
    let at = |at: u64, past: bool| ListKey {
        last_activity: at,
        chat_id: String::new(),
        origin: "local".into(),
        past,
    };
    let local = key(50, "local");
    assert_eq!(peer_resume_key(ReadSide::After, &local), Some(wire_key(local.clone())));
    assert_eq!(peer_resume_key(ReadSide::Before, &local), Some(wire_key(local)));
    assert_eq!(peer_resume_key(ReadSide::After, &key(50, "c-machine")), Some(at(50, false)));
    assert_eq!(peer_resume_key(ReadSide::After, &key(50, "z-machine")), Some(at(49, false)));
    assert_eq!(peer_resume_key(ReadSide::After, &key(0, "z-machine")), None);
    assert_eq!(peer_resume_key(ReadSide::Before, &key(50, "z-machine")), Some(at(50, true)));
    assert_eq!(peer_resume_key(ReadSide::Before, &key(50, "c-machine")), Some(at(51, true)));
    assert_eq!(peer_resume_key(ReadSide::Before, &key(u64::MAX, "c-machine")), None);
    // The bound is past every local key at its time and before every later origin's.
    let bound = peer_past_bound(&at(50, true)).unwrap();
    assert!(bound < key(50, "z-machine") && bound < key(50, "local\u{1}"));
    assert!(bound > key(50, "local") && bound > key(50, "c-machine"));
    assert!(bound > SortKey { last_activity: 50, row: RowKey::new("local", "\u{10FFFF}") });
}

#[test]
fn a_false_past_is_todays_bytes_and_a_true_one_round_trips() {
    let key =
        ListKey { last_activity: 7, chat_id: "a".into(), origin: "local".into(), past: false };
    assert_eq!(
        serde_json::to_string(&key).unwrap(),
        r#"{"lastActivity":7,"chatId":"a","origin":"local"}"#
    );
    let today: ListKey =
        serde_json::from_str(r#"{"lastActivity":7,"chatId":"a","origin":"local"}"#).unwrap();
    assert_eq!(today, key);
    let text = serde_json::to_string(&past(7)).unwrap();
    assert_eq!(text, r#"{"lastActivity":7,"chatId":"","origin":"local","past":true}"#);
    assert_eq!(serde_json::from_str::<ListKey>(&text).unwrap(), past(7));
}

#[test]
fn a_past_key_is_refused_at_every_other_door() {
    let (hub, _, _) = hub();
    let refused = |result: Result<Frame, HubError>, door: &str| {
        assert!(matches!(result, Err(HubError::InvalidPage)), "{door}: {result:?}");
    };
    // The one place it is taken.
    assert!(hub.peer_page(&all_page(PageSide::Before, Some(past(500)), None)).is_ok());
    // One spelling: origin local, chat id "", past true.
    let spelled = |edit: fn(&mut ListKey)| {
        let mut key = past(500);
        edit(&mut key);
        all_page(PageSide::Before, Some(key), None)
    };
    refused(hub.peer_page(&spelled(|key| key.origin = "c-machine".into())), "another origin");
    refused(hub.peer_page(&spelled(|key| key.chat_id = "b-500-0".into())), "a chat id");
    // A peer's page on side after, a live page, a keys page.
    refused(hub.peer_page(&all_page(PageSide::After, Some(past(500)), None)), "peer after");
    let mut live = all_page(PageSide::Before, Some(past(500)), None);
    live.view = Some(ListView::Live);
    refused(hub.peer_page(&live), "peer live");
    let mut keys = all_page(PageSide::After, None, None);
    keys.keys = Some(vec![PageKey::Summary(past(500))]);
    refused(hub.peer_page(&keys), "peer keys");
    // A local connection's pages: all on either side, live, keys (a client's wanted rows).
    refused(hub.page(&all_page(PageSide::Before, Some(past(500)), None)), "local before");
    refused(hub.page(&all_page(PageSide::After, Some(past(500)), None)), "local after");
    refused(hub.page(&live), "local live");
    refused(hub.page(&keys), "local keys");
    // A sub's anchor, local and peer.
    let mut sub = Sub::new("windows", "list");
    sub.anchor = Some(Anchor::List { key: past(500), side: AnchorSide::Before });
    sub.view = Some(ListView::All);
    assert!(matches!(hub.list_window(&sub), Err(HubError::InvalidPage)), "local sub");
    sub.view = Some(ListView::Live);
    assert!(matches!(hub.peer_window(&sub), Err(HubError::InvalidPage)), "peer sub");
    // A folders page takes folder positions only.
    let mut folders = all_page(PageSide::Before, Some(past(500)), None);
    folders.view = Some(ListView::Folders);
    assert!(hub.page(&folders).is_err(), "folders");
}

/// A hub whose rows are read from a sorted snapshot, as `rows` (activity, origin, chat id)
/// list them, and its local chat ids in the keys' order. Local rows are closed; other
/// machines' rows are live, since a snapshot holds another origin's rows only while live.
fn snapshot_hub(rows: &[(u64, &str, String)]) -> (Hub, Vec<String>, tempfile::TempDir) {
    use acpmux_book::index::{DiskSnapshot, SortedSnapshot};
    let mut index = SummaryIndex::new();
    let mut local = Vec::new();
    for (seq, (at, origin, id)) in rows.iter().enumerate() {
        let mut summary = Summary::new(id.clone());
        summary.origin = (*origin).to_owned();
        summary.state = if *origin == "local" { "closed" } else { "running" }.into();
        summary.title = "a row of fixed width".into();
        summary.last_activity = *at;
        if *origin == "local" {
            local.push((SortKey::of(&summary), id.clone()));
        }
        index = index.apply(seq as u64 + 1, summary);
    }
    local.sort();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.snap");
    SortedSnapshot::write(&path, &index).unwrap();
    let (hub, _writer) = Hub::new(SummaryIndex::from_disk(DiskSnapshot::open(&path).unwrap(), 1));
    (hub, local.into_iter().map(|(_, id)| id).collect(), dir)
}

/// An `all` page on `side` from `from` whose budget holds 20 of these rows.
fn budget_page(side: PageSide, from: Option<ListKey>) -> Page {
    // As wide as the tests' local rows: a four-digit activity time.
    let mut row = Summary::new("b-00000".to_owned());
    row.last_activity = 1_000;
    row.state = "closed".into();
    row.title = "a row of fixed width".into();
    let mut page = all_page(side, from, None);
    page.max_bytes = u32::try_from(8192 + page.sid.len() + 20 * (row.encoded_len() + 1)).unwrap();
    page
}

/// One page, its pieces, its snapshot bytes and its frame's length, from one request, by the
/// same checks as [`read`].
fn read_counted(hub: &Hub, page: &Page) -> (PageResult<Value>, usize, usize, usize) {
    let frame_len = hub.peer_page(page).unwrap().encoded_len();
    let (result, _) = read(hub, page);
    let (pieces, bytes) = PEER_PIECES.with(|read| read.get());
    (result, pieces, bytes, frame_len)
}

#[test]
fn a_snapshot_run_longer_than_the_cap_answers_empty_then_walks_on() {
    // 2,000 third-machine rows on each side of local in the order, then 20 local rows.
    let mut rows = Vec::new();
    for m in 0..2_000u64 {
        rows.push((5_000 - m, "c-machine", format!("c-{m:05}")));
        rows.push((5_000 - m, "z-machine", format!("z-{m:05}")));
    }
    for n in 0..20u64 {
        rows.push((1_000 - n, "local", format!("b-{n:05}")));
    }
    let (hub, local, _dir) = snapshot_hub(&rows);
    let (result, pieces, bytes, _) = read_counted(&hub, &budget_page(PageSide::After, None));
    assert_eq!(pieces, PEER_PAGE_PIECES, "the first request reads exactly the cap");
    assert!(result.rows.is_empty() && result.has_after, "empty, with more to follow");
    assert!(!result.has_before, "an unanchored page has nothing before the newest end");
    // Decision 294: each piece is at most a full piece and its seek's block, plus the seek's
    // checkpoint search: the last checkpoint and a binary search, under CHECKPOINT_STEPS reads.
    const CHECKPOINT_STEPS: usize = 64;
    let bound = PEER_PAGE_PIECES
        * (acpmux_book::index::PAGE_BYTES
            + acpmux_book::index::SEEK_BYTES
            + CHECKPOINT_STEPS * acpmux_book::index::CHECKPOINT_BYTES);
    assert!(bytes > 0 && bytes <= bound, "{bytes} snapshot bytes for one request, bound {bound}");
    for (side, from) in [(PageSide::After, None), (PageSide::Before, Some(past(0)))] {
        let (seen, _, most) = walk_page(&hub, side, budget_page(side, from));
        assert_eq!(seen, local, "{side:?}: every local row once, and the walk ends");
        assert!(most <= PEER_PAGE_PIECES, "{side:?}");
    }
}

#[test]
fn a_page_whose_first_piece_holds_a_local_row_reads_as_a_local_page_does() {
    let mut rows = Vec::new();
    for n in 0..20u64 {
        rows.push((5_000 - n, "local", format!("b-{n:05}")));
    }
    for m in 0..2_000u64 {
        rows.push((4_000 - m, "c-machine", format!("c-{m:05}")));
    }
    let (hub, _, _dir) = snapshot_hub(&rows);
    let page = budget_page(PageSide::After, None);
    let (result, pieces, bytes, _) = read_counted(&hub, &page);
    assert_eq!(pieces, 1);
    assert_eq!(result.rows.len(), 20);
    let local = hub
        .snapshot()
        .read_page(
            None,
            ReadSide::After,
            false,
            MAX_WINDOW_ROWS,
            page.max_bytes as usize - 8192 - page.sid.len(),
            None,
        )
        .unwrap();
    assert!(bytes > 0);
    assert_eq!(bytes, local.bytes_read, "the bytes a local connection's page reads");
}

#[test]
fn a_full_piece_with_more_local_rows_than_the_budget_is_cut_to_it() {
    // A first piece of third-machine rows only, then a full piece of local rows.
    let mut rows = Vec::new();
    for m in 0..300u64 {
        rows.push((9_000 - m, "c-machine", format!("c-{m:05}")));
    }
    for n in 0..500u64 {
        rows.push((8_000 - n, "local", format!("b-{n:05}")));
    }
    for m in 0..300u64 {
        rows.push((7_000 - m, "z-machine", format!("z-{m:05}")));
    }
    let (hub, local, _dir) = snapshot_hub(&rows);
    for (side, from) in [(PageSide::After, None), (PageSide::Before, Some(past(0)))] {
        let page = budget_page(side, from);
        let (result, pieces, _, frame_len) = read_counted(&hub, &page);
        assert!(pieces >= 2, "{side:?}: the first piece held no local row");
        assert_eq!(result.rows.len(), 20, "{side:?}: cut to the budget");
        assert!(frame_len <= page.max_bytes as usize, "{side:?}: within the asker's max");
        // Each next page starts at the first row left out: the walk is every row once.
        let (seen, _, _) = walk_page(&hub, side, page);
        assert_eq!(seen, local, "{side:?}");
    }
}
