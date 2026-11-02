//! `acpmux ls` reads a list of any size in pages, against the hub's own paging
//! (`hub/session_pages.rs`) as a fake daemon.

use std::cell::{Cell, RefCell};

use serde_json::{Value, json};

use super::*;
use crate::client::DaemonError;
use crate::hub::session_pages::{session_list_reply, sort_session_summaries};
use crate::rpc::RpcError;

/// `n` sessions, newest first, each with a title `pad` bytes long; every third on a peer.
fn sessions(n: u64, pad: usize) -> Vec<Value> {
    let mut rows: Vec<Value> = (0..n)
        .map(|i| {
            let mut row = json!({"sessionId": format!("s{i:05}"), "updatedAt": 10_000 + i,
                "status": if i % 2 == 0 { "closed" } else { "idle" }, "title": "t".repeat(pad)});
            if i % 3 == 0 {
                row["peer"] = json!("peer-1");
            }
            row
        })
        .collect();
    sort_session_summaries(&mut rows);
    rows
}

/// What a fake daemon saw: the requests it answered or refused, and its longest reply.
#[derive(Default)]
struct Seen {
    requests: Cell<usize>,
    largest: Cell<usize>,
}

/// A daemon over `list` that refuses, as `rpc.rs` does, a reply longer than `cap` bytes.
fn daemon(
    list: &RefCell<Vec<Value>>,
    cap: usize,
) -> impl FnMut(Value) -> std::future::Ready<Result<Value>> + '_ {
    counted(list, cap, None)
}

/// [`daemon`], noting what it sees in `seen`.
fn counted<'a>(
    list: &'a RefCell<Vec<Value>>,
    cap: usize,
    seen: Option<&'a Seen>,
) -> impl FnMut(Value) -> std::future::Ready<Result<Value>> + 'a {
    move |params| {
        if let Some(seen) = seen {
            seen.requests.set(seen.requests.get() + 1);
        }
        let reply = session_list_reply(list.borrow().clone(), &params)
            .map_err(|e| anyhow::Error::from(DaemonError(e)));
        std::future::ready(reply.and_then(|reply| {
            let bytes = reply.to_string().len();
            if bytes > cap {
                return Err(DaemonError(RpcError::too_large(bytes)).into());
            }
            if let Some(seen) = seen {
                seen.largest.set(seen.largest.get().max(bytes));
            }
            Ok(reply)
        }))
    }
}

fn plan(size: u64) -> Plan {
    Plan { size, want: None, one: false, exact: true }
}

fn ids(rows: &[Value]) -> Vec<&str> {
    rows.iter().map(|r| r["sessionId"].as_str().unwrap()).collect()
}

fn keep(_: &Value) -> Step {
    Step::Keep
}

async fn read_all(
    list: &RefCell<Vec<Value>>,
    plan: Plan,
    cap: usize,
    seen: &Seen,
) -> Result<Pages> {
    read(json!({}), None, plan, keep, counted(list, cap, Some(seen))).await
}

#[tokio::test]
async fn a_list_larger_than_a_page_is_read_whole_each_row_once() {
    let list = RefCell::new(sessions(2_503, 10));
    let seen = Seen::default();
    let got = read_all(&list, plan(PAGE_ROWS), usize::MAX, &seen).await.unwrap();
    assert_eq!(ids(&got.rows), ids(&list.borrow()));
    assert_eq!(seen.requests.get(), 2);
    assert_eq!(got.next, Some(Value::Null));
}

/// A fleet host, 2026-10-30: 3,700 sessions of about 9 KB come to 33 MB, past the 31 MiB a
/// reply may hold. Later pages use the measured available space.
#[tokio::test]
async fn a_busy_hosts_list_goes_in_pages_under_the_message_limit() {
    let list = RefCell::new(sessions(3_700, 9_000));
    let whole = json!({"sessions": *list.borrow()}).to_string().len();
    assert!(whole > crate::rpc::MAX_MESSAGE_BYTES, "{whole}");
    let seen = Seen::default();
    let got = read_all(&list, plan(PAGE_ROWS), crate::rpc::MAX_MESSAGE_BYTES, &seen).await.unwrap();
    assert_eq!(got.rows.len(), 3_700);
    assert_eq!(seen.requests.get(), 3);
    let largest = seen.largest.get();
    assert!(largest < crate::rpc::MAX_MESSAGE_BYTES, "{largest}");
}

#[tokio::test]
async fn a_page_too_large_to_send_is_asked_again_at_half_the_rows() {
    let list = RefCell::new(sessions(300, 1_000));
    let seen = Seen::default();
    let got = read_all(&list, plan(PAGE_ROWS), 40_000, &seen).await.unwrap();
    assert_eq!(ids(&got.rows), ids(&list.borrow()));
    // 1000, 500, 250, 125 and 62 refused (every page over 40 KB), then pages of 31.
    assert_eq!(seen.requests.get(), 5 + 10);
}

#[tokio::test]
async fn one_row_too_large_to_send_names_the_fix() {
    let list = RefCell::new(sessions(5, 50_000));
    let e = read_all(&list, plan(8), 10_000, &Seen::default()).await.unwrap_err();
    let text = e.to_string();
    assert!(text.contains("acpmux session info") && text.contains("MiB"), "{text}");
}

/// A row that comes again (its cursor's row left, so the next page starts at the first row no
/// newer than it: rows of that same millisecond repeat) is kept once.
#[tokio::test]
async fn a_row_a_later_page_repeats_is_kept_once() {
    let mut rows = sessions(6, 1);
    for row in &mut rows {
        row["updatedAt"] = json!(7);
    }
    sort_session_summaries(&mut rows);
    let list = RefCell::new(rows.clone());
    let calls = Cell::new(0);
    let mut fake = daemon(&list, usize::MAX);
    let fetch = |params| {
        let reply = fake(params);
        if calls.replace(calls.get() + 1) == 0 {
            // The second row, which the first page ends on, leaves.
            list.borrow_mut().remove(1);
        }
        reply
    };
    let got = read(json!({}), None, plan(2), keep, fetch).await.unwrap();
    assert_eq!(ids(&got.rows), ids(&rows));
}

#[tokio::test]
async fn a_limit_ends_on_a_page_and_its_cursor_starts_the_next_rows() {
    let list = RefCell::new(sessions(400, 1));
    let want = Plan { want: Some(150), ..plan(100) };
    let first = read_all(&list, want, usize::MAX, &Seen::default()).await.unwrap();
    assert_eq!(ids(&first.rows), ids(&list.borrow()[..150]));
    let Some(Value::String(next)) = first.next else { panic!("{:?}", first.next) };
    let one = Plan { one: true, ..plan(100) };
    let second = read(json!({}), Some(next), one, keep, daemon(&list, usize::MAX)).await.unwrap();
    assert_eq!(ids(&second.rows), ids(&list.borrow()[150..250]));
    assert!(matches!(second.next, Some(Value::String(_))));
}

/// The daemon drops what its filters leave out before it pages; `step` drops it again for one
/// too old for them, and a `--since` row ends the read.
#[tokio::test]
async fn filters_go_to_the_daemon_and_since_ends_the_read() {
    let list = RefCell::new(sessions(100, 1));
    let params = json!({"excludeStatus": ["closed"], "localOnly": true});
    let got = read(params, None, plan(10), keep, daemon(&list, usize::MAX)).await.unwrap();
    assert!(got.rows.iter().all(|r| r["status"] == "idle" && r.get("peer").is_none()));
    assert_eq!(got.rows.len(), 33);
    let newest = |row: &Value| {
        if row["updatedAt"].as_u64().unwrap() < 10_090 { Step::Stop } else { Step::Keep }
    };
    let seen = Seen::default();
    let fetch = counted(&list, usize::MAX, Some(&seen));
    let got = read(json!({}), None, plan(4), newest, fetch).await.unwrap();
    assert_eq!(got.rows.len(), 10);
    assert_eq!(seen.requests.get(), 3);
    assert_eq!(got.next, Some(Value::Null));
}

/// A daemon too old for `limit` sends every row at once, with no cursor: that is the list. A
/// limit that stops in it has no cursor to hand on.
#[tokio::test]
async fn a_daemon_too_old_for_pages_sends_the_whole_list() {
    let rows = sessions(30, 1);
    let old = |_: Value| std::future::ready(Ok(json!({"sessions": rows.clone()})));
    let got = read(json!({}), None, plan(10), keep, old).await.unwrap();
    assert_eq!(got.rows.len(), 30);
    assert_eq!(got.next, Some(Value::Null));
    let got = read(json!({}), None, Plan { want: Some(5), ..plan(10) }, keep, old).await.unwrap();
    assert_eq!(got.rows.len(), 5);
    assert_eq!(got.next, None);
}

#[tokio::test]
async fn a_cursor_that_comes_again_and_again_is_an_error_not_a_loop() {
    let looping = |_: Value| {
        std::future::ready(Ok(json!({"sessions": [{"sessionId": "a"}], "nextCursor": "k1.1"})))
    };
    let e = read(json!({}), None, plan(1), keep, looping).await.unwrap_err();
    assert!(e.to_string().contains("again and again"), "{e}");
}

/// A chat here and its copy on a peer, updated in the same millisecond, share one cursor: a page
/// that ends on the copy names it, and the page after starts at the copy again. The read widens
/// that page and goes on, each row once (the old single request listed them all).
#[tokio::test]
async fn a_cursor_a_chat_and_its_peer_copy_share_is_read_past() {
    let rows = with_a_peer_copy();
    let list = RefCell::new(rows.clone());
    // Four rows ending on the copy, then a page of one: the copy again, under the same cursor.
    let want = Plan { want: Some(5), ..plan(4) };
    let got = read(json!({}), None, want, keep, old_daemon(&list, usize::MAX)).await.unwrap();
    let keys: Vec<_> =
        got.rows.iter().map(|r| (r["sessionId"].clone(), r["peer"].clone())).collect();
    let all: Vec<_> = rows.iter().map(|r| (r["sessionId"].clone(), r["peer"].clone())).collect();
    assert_eq!(keys, all[..5]);
    let whole = read(json!({}), None, plan(3), keep, old_daemon(&list, usize::MAX)).await.unwrap();
    assert_eq!(whole.rows.len(), 7);
}

/// `--limit` with a filter the daemon does not apply stops in the middle of a page; the cursor it
/// hands on starts the next matching rows, none skipped or repeated.
#[tokio::test]
async fn a_limit_a_client_filter_ends_mid_page_hands_on_the_next_rows() {
    let list = RefCell::new(sessions(400, 1));
    let tenth = |row: &Value| {
        let n: u64 = row["sessionId"].as_str().unwrap()[1..].parse().unwrap();
        if n.is_multiple_of(10) { Step::Keep } else { Step::Skip }
    };
    let want = |n| Plan { want: Some(n), exact: false, ..plan(100) };
    let mut fake = daemon(&list, usize::MAX);
    let first = read(json!({}), None, want(7), tenth, &mut fake).await.unwrap();
    assert_eq!(first.rows.len(), 7);
    let Some(Value::String(next)) = first.next else { panic!("{:?}", first.next) };
    let second = read(json!({}), Some(next), want(50), tenth, &mut fake).await.unwrap();
    let all = read(json!({}), None, want(57), tenth, &mut fake).await.unwrap();
    let both: Vec<&str> = ids(&first.rows).into_iter().chain(ids(&second.rows)).collect();
    assert_eq!(both, ids(&all.rows));
    assert_eq!(second.rows.len(), 33);
    assert_eq!(second.next, Some(Value::Null));
}

/// A daemon too old for pages ignores `cursor` and sends its list from the start: `--cursor`
/// against it is refused, never a page that repeats the first one.
#[tokio::test]
async fn a_cursor_against_a_daemon_too_old_for_pages_is_refused() {
    let rows = sessions(30, 1);
    let old = |_: Value| std::future::ready(Ok(json!({"sessions": rows.clone()})));
    let one = Plan { one: true, ..plan(10) };
    let e = read(json!({}), Some("k1.1".into()), one, keep, old).await.unwrap_err();
    assert!(e.to_string().contains("too old to page"), "{e}");
}

/// A daemon from before #28161, whose cursor names a session's id and time but not its peer (as
/// the fleet's ran on 2026-10-30): a chat here and its copy on a peer updated in one millisecond
/// share a cursor, and the page after it starts after the first of them. It refuses, as
/// `rpc.rs` does, a reply longer than `cap` bytes.
fn old_daemon(
    list: &RefCell<Vec<Value>>,
    cap: usize,
) -> impl FnMut(Value) -> std::future::Ready<Result<Value>> + '_ {
    let cursor_of = |row: &Value| format!("{}@{}", row["sessionId"], row["updatedAt"]);
    move |params| {
        let rows = list.borrow();
        let limit = usize::try_from(params["limit"].as_u64().unwrap()).unwrap();
        let start = params["cursor"].as_str().map_or(0, |c| {
            rows.iter().position(|r| cursor_of(r) == c).map_or(rows.len(), |at| at + 1)
        });
        let page: Vec<Value> = rows.iter().skip(start).take(limit).cloned().collect();
        let next = (start + page.len() < rows.len()).then(|| cursor_of(page.last().unwrap()));
        let reply = json!({"sessions": page, "nextCursor": next});
        let bytes = reply.to_string().len();
        std::future::ready(if bytes > cap {
            Err(DaemonError(RpcError::too_large(bytes)).into())
        } else {
            Ok(reply)
        })
    }
}

/// Rows 5 and 4, then row 3 here and its copy on a peer in one millisecond, then rows 2 to 0.
fn with_a_peer_copy() -> Vec<Value> {
    let mut rows = sessions(6, 1);
    for row in &mut rows {
        row.as_object_mut().unwrap().remove("peer");
    }
    let mut copy = rows[2].clone();
    copy["peer"] = json!("peer-1");
    rows.insert(3, copy);
    rows
}

fn key(row: &Value) -> (Value, Value) {
    (row["sessionId"].clone(), row["peer"].clone())
}

/// A script paging one row at a time with `--cursor` gets past the copy: every row comes, the
/// copy perhaps twice, and the pages end.
#[tokio::test]
async fn one_row_pages_by_cursor_get_past_a_peer_copy() {
    let rows = with_a_peer_copy();
    let list = RefCell::new(rows.clone());
    let (mut got, mut cursor, mut calls) = (Vec::new(), None, 0);
    loop {
        calls += 1;
        assert!(calls < 20, "{got:?}");
        let one = Plan { one: true, ..plan(1) };
        let page = read(json!({}), cursor, one, keep, old_daemon(&list, usize::MAX)).await.unwrap();
        got.extend(page.rows.iter().map(key));
        match page.next {
            Some(Value::String(next)) => cursor = Some(next),
            next => {
                assert_eq!(next, Some(Value::Null));
                break;
            }
        }
    }
    let mut unique = got.clone();
    unique.dedup();
    assert_eq!(unique, rows.iter().map(key).collect::<Vec<_>>(), "{got:?}");
}

/// Rows that fit one to a page but not two: past a shared cursor a page of one makes no way and
/// a wider one is too large to send. The read halves and widens a bounded number of times and
/// ends in an error, never goes on for ever.
#[tokio::test]
async fn a_widened_page_too_large_to_send_ends_in_an_error() {
    let mut rows = with_a_peer_copy();
    for row in &mut rows {
        row["title"] = json!("t".repeat(6_000));
    }
    let list = RefCell::new(rows);
    let want = Plan { want: Some(6), ..plan(4) };
    let e = read(json!({}), None, want, keep, old_daemon(&list, 10_000)).await.unwrap_err();
    assert!(e.to_string().contains("again and again"), "{e}");
}

/// Every pair of a chat and its peer copy costs a page one repeated cursor; more pairs than
/// [`MAX_REPEATS`] are still read whole, as each widened page moves on.
#[tokio::test]
async fn many_peer_copies_are_read_past_one_after_another() {
    let mut rows = Vec::new();
    for i in 0..20u64 {
        let row =
            json!({"sessionId": format!("s{i:02}"), "updatedAt": 1_000 - i, "status": "idle"});
        let mut copy = row.clone();
        copy["peer"] = json!("peer-1");
        rows.extend([row, copy]);
    }
    let list = RefCell::new(rows.clone());
    let got = read(json!({}), None, plan(1), keep, old_daemon(&list, usize::MAX)).await.unwrap();
    assert_eq!(
        got.rows.iter().map(key).collect::<Vec<_>>(),
        rows.iter().map(key).collect::<Vec<_>>()
    );
}

/// The reported host mirrors about 8,000 rows. Full pages must enumerate every
/// local/peer identity without eight separately paced snapshot requests.
#[tokio::test]
async fn an_eight_thousand_row_peer_census_uses_fuller_pages() {
    let mut rows = sessions(8_000, 3_000);
    for (n, row) in rows.iter_mut().enumerate().skip(445) {
        row["peer"] = json!(format!("peer-{}", n % 20));
    }
    let list = RefCell::new(rows);
    // Same fake daemon, rows and size cap; the baseline enforces the old fixed
    // request size while still exercising the production cursor/dedup reader.
    let baseline = Seen::default();
    let mut fixed = counted(&list, crate::rpc::MAX_MESSAGE_BYTES, Some(&baseline));
    let started = std::time::Instant::now();
    let before = read(json!({}), None, plan(PAGE_ROWS), keep, |mut params| {
        params["limit"] = json!(PAGE_ROWS);
        fixed(params)
    })
    .await
    .unwrap();
    let before_ms = started.elapsed().as_secs_f64() * 1000.0;
    let seen = Seen::default();
    let started = std::time::Instant::now();
    let got = read_all(&list, plan(PAGE_ROWS), crate::rpc::MAX_MESSAGE_BYTES, &seen).await.unwrap();
    let after_ms = started.elapsed().as_secs_f64() * 1000.0;
    assert_eq!(before.rows, *list.borrow());
    assert_eq!(got.rows, before.rows);
    assert_eq!(baseline.requests.get(), 8);
    // A first page of PAGE_ROWS, then pages learned to fill three quarters of the 31 MiB limit
    // (`fuller_page`): the rest of the 8,000 rows in one more.
    assert_eq!(seen.requests.get(), 2);
    assert!(seen.largest.get() < crate::rpc::MAX_MESSAGE_BYTES);
    eprintln!(
        "8000-row census: fixed={} requests, {before_ms:.3} ms; adaptive={} requests, {after_ms:.3} ms; largest={} bytes",
        baseline.requests.get(),
        seen.requests.get(),
        seen.largest.get()
    );
}

#[tokio::test]
async fn larger_later_rows_shrink_the_learned_page_without_repeated_growth() {
    let mut rows = sessions(4_000, 10);
    for row in rows.iter_mut().skip(1_000) {
        row["title"] = json!("x".repeat(8_000));
    }
    let list = RefCell::new(rows);
    let seen = Seen::default();
    let got = read_all(&list, plan(PAGE_ROWS), crate::rpc::MAX_MESSAGE_BYTES, &seen).await.unwrap();
    assert_eq!(got.rows, *list.borrow());
    assert!(seen.requests.get() < 20, "{}", seen.requests.get());
    assert!(seen.largest.get() < crate::rpc::MAX_MESSAGE_BYTES);
}
