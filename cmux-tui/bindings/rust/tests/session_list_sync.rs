//! A session list row that runs ahead of its journal body never shows as new
//! and never notifies (`spec/session-journal.md`, "Session list rows").
//!
//! The timeline is simulated in 100 ms ticks, so the 5 s delay costs no wall
//! time and the test is deterministic. Two sessions get a row and an "agent
//! finished" notification at t = 0. Session B's journal arrives at once;
//! session A's journal stream is held back 5 s.

use std::collections::VecDeque;

use cmux::SessionSnapshot;
use cmux::session_list_sync::{RowSync, SessionListSync, row_journal_head};
use serde_json::json;

const MACHINE: &str = "machine_00000000000000000000000000000001";
const SESSION_A: &str = "session_0000000000000000000000000000000a";
const SESSION_B: &str = "session_0000000000000000000000000000000b";
const TICK_MS: u64 = 100;
const STREAM_DELAY_MS: u64 = 5_000;
const HEAD: u64 = 7;

fn row(id: &str, head: Option<u64>) -> SessionSnapshot {
    let mut value = json!({
        "id": id, "machine_id": MACHINE, "generation": "g",
        "revision": "3", "connected": true,
    });
    if let Some(head) = head {
        value["extra"] = json!({"journal_head_sequence": head.to_string()});
    }
    serde_json::from_value(value).unwrap()
}

/// One session's journal stream as the viewer receives it: record `n` is
/// delivered at `delay + n * 10 ms`.
fn stream(delay_ms: u64) -> VecDeque<(u64, u64)> {
    (1..=HEAD).map(|sequence| (delay_ms + sequence * 10, sequence)).collect()
}

#[test]
fn a_row_ahead_of_its_delayed_journal_shows_syncing_and_notifies_nothing_until_the_body_arrives() {
    let a = row(SESSION_A, Some(HEAD));
    let b = row(SESSION_B, Some(HEAD));
    let mut sync = SessionListSync::<&'static str>::new();
    let mut streams = [(a.id.clone(), stream(STREAM_DELAY_MS)), (b.id.clone(), stream(0))];

    // t = 0: both rows arrive, both unread, both offer their notification.
    sync.observe_row(&a);
    sync.observe_row(&b);
    let mut fired: Vec<(u64, String)> = Vec::new();
    for session in [&a.id, &b.id] {
        if sync.offer(session, "agent finished").is_some() {
            fired.push((0, session.as_str().to_owned()));
        }
    }

    let mut early_notifications = fired.len();
    let mut early_new_rows = 0;
    let mut a_synced_at = None;
    let mut now = 0;
    while now <= STREAM_DELAY_MS + 1_000 {
        for (session, records) in &mut streams {
            while records.front().is_some_and(|(at, _)| *at <= now) {
                let (_, sequence) = records.pop_front().unwrap();
                sync.observe_cursor(session, sequence);
            }
        }
        for (session, _) in sync.take_released() {
            fired.push((now, session.as_str().to_owned()));
        }
        // The invariant, at every tick: nothing behind its head is new or notified.
        for session in [&a.id, &b.id] {
            let behind = matches!(sync.sync(session), RowSync::Syncing { .. });
            if behind && sync.row(session, true).new {
                early_new_rows += 1;
            }
            if behind && fired.iter().any(|(at, id)| *at == now && id == session.as_str()) {
                early_notifications += 1;
            }
        }
        if a_synced_at.is_none() && sync.sync(&a.id) == RowSync::Synced {
            a_synced_at = Some(now);
        }
        if now < STREAM_DELAY_MS {
            assert!(
                matches!(sync.sync(&a.id), RowSync::Syncing { head: HEAD, .. }),
                "A is syncing at {now} ms"
            );
            assert!(!sync.row(&a.id, true).new, "A is not new at {now} ms");
            assert!(fired.iter().all(|(_, id)| id != SESSION_A), "A notified at {now} ms");
        }
        now += TICK_MS;
    }

    assert_eq!(early_notifications, 0, "notifications fired while the cursor was behind head");
    assert_eq!(early_new_rows, 0, "rows shown as new while the cursor was behind head");
    // B's body came at once: it notified once, within the first tick.
    let b_fired: Vec<_> = fired.iter().filter(|(_, id)| id == SESSION_B).collect();
    assert_eq!(b_fired.len(), 1);
    assert!(b_fired[0].0 <= TICK_MS);
    // A notified exactly once, after its body arrived 5 s late.
    let a_fired: Vec<_> = fired.iter().filter(|(_, id)| id == SESSION_A).collect();
    assert_eq!(a_fired.len(), 1);
    assert!(a_fired[0].0 >= STREAM_DELAY_MS);
    assert_eq!(Some(a_fired[0].0), a_synced_at);
    assert!(sync.row(&a.id, true).new);
    assert_eq!(sync.held_count(), 0);
}

#[test]
fn a_stale_row_never_moves_the_head_back_and_a_row_without_a_head_is_never_held() {
    let mut sync = SessionListSync::<u32>::new();
    let fresh = row(SESSION_A, Some(9));
    sync.observe_row(&fresh);
    sync.observe_row(&row(SESSION_A, Some(2)));
    sync.observe_cursor(&fresh.id, 2);
    assert_eq!(sync.sync(&fresh.id), RowSync::Syncing { cursor: 2, head: 9 });
    assert_eq!(sync.offer(&fresh.id, 1), None);
    assert_eq!(sync.offer(&fresh.id, 2), None);
    sync.observe_cursor(&fresh.id, 9);
    let released: Vec<u32> = sync.take_released().into_iter().map(|(_, n)| n).collect();
    assert_eq!(released, vec![1, 2], "held notifications come out once, in offer order");
    assert!(sync.take_released().is_empty());

    // A daemon that predates the field: the row is never held.
    let old = row(SESSION_B, None);
    assert_eq!(row_journal_head(&old), None);
    sync.observe_row(&old);
    assert_eq!(sync.offer(&old.id, 3), Some(3));
}

#[test]
fn only_a_canonical_decimal_head_counts() {
    for (raw, head) in [("0", Some(0)), ("42", Some(42)), ("042", None), ("", None), ("-1", None)] {
        let snapshot: SessionSnapshot = serde_json::from_value(json!({
            "id": SESSION_A, "machine_id": MACHINE, "generation": "g", "revision": "1",
            "connected": true, "extra": {"journal_head_sequence": raw},
        }))
        .unwrap();
        assert_eq!(row_journal_head(&snapshot), head, "{raw:?}");
    }
}
