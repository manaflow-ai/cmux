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
    PEER_PIECES.with(|read| read.set(0));
    let frame = hub.peer_page(page).expect("a peer's all page");
    let pieces = PEER_PIECES.with(|read| read.get());
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
    let mut page = all_page(side, from, filter);
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
