use cmux_auto_session::wire::{Holder, State as Shown};
use serde_json::json;

use super::*;

fn view(epoch: u64, last_seq: u64) -> SessionView {
    SessionView {
        id: "c".into(),
        title: String::new(),
        harness: String::new(),
        team: None,
        owner: String::new(),
        auto: true,
        keep_in_cloud: false,
        holder: Holder::vm("m1"),
        epoch,
        state: Shown::Cloud,
        blocked: None,
        needs_run: true,
        standby: Vec::new(),
        last_seq,
        snapshot: 0,
        inbox: 0,
        inbox_acked: 0,
        repo: None,
        version: 1,
        created_at: 0,
        updated_at: 0,
        lease_expires_at: 0,
        moving: None,
    }
}

fn event(seq: u64, text: &str) -> SeqRecord {
    SeqRecord { seq, record: json!({"seq": seq, "text": text}) }
}

fn page(seqs: &[(u64, &str)], last_seq: u64) -> EventsPage {
    EventsPage { events: seqs.iter().map(|(seq, text)| event(*seq, text)).collect(), last_seq }
}

fn seqs(buffer: &Buffer) -> Vec<u64> {
    buffer.events.iter().map(|event| event.seq).collect()
}

#[test]
fn repeated_and_overlapping_pages_keep_each_seq_once_in_order() {
    let mut buffer = Buffer::new(0);
    assert_eq!(buffer.observe(&view(2, 3), 1), Next { verify: None });
    assert!(buffer.take(page(&[(1, "a"), (2, "b")], 3)));
    assert!(buffer.take(page(&[(1, "a"), (2, "b"), (3, "c")], 3)));
    assert!(buffer.take(page(&[(3, "c")], 3)));
    assert_eq!(seqs(&buffer), [1, 2, 3]);
    assert!(buffer.caught_up());
}

#[test]
fn a_gap_stops_the_page_and_is_read_again() {
    let mut buffer = Buffer::new(0);
    buffer.observe(&view(2, 4), 1);
    assert!(!buffer.take(page(&[(1, "a"), (3, "c")], 4)));
    assert_eq!(seqs(&buffer), [1]);
    assert!(buffer.take(page(&[(2, "b"), (3, "c"), (4, "d")], 4)));
    assert_eq!(seqs(&buffer), [1, 2, 3, 4]);
}

#[test]
fn a_shorter_store_log_starts_the_projection_over() {
    let mut buffer = Buffer::new(0);
    buffer.observe(&view(2, 3), 1);
    buffer.take(page(&[(1, "a"), (2, "b"), (3, "c")], 3));
    // The chat was closed and opened again, empty, at a later epoch.
    assert_eq!(buffer.observe(&view(4, 1), 2), Next { verify: None });
    assert_eq!(buffer.resets, 1);
    assert!(seqs(&buffer).is_empty());
    assert!(buffer.take(page(&[(1, "new")], 1)));
    assert_eq!(seqs(&buffer), [1]);
}

#[test]
fn an_epoch_change_checks_the_kept_end_and_starts_over_when_it_differs() {
    let mut buffer = Buffer::new(0);
    buffer.observe(&view(2, 2), 1);
    buffer.take(page(&[(1, "a"), (2, "b")], 2));
    // Same log, another holder: the kept end is the store's, so nothing is read twice.
    let next = buffer.observe(&view(3, 3), 2);
    assert_eq!(next, Next { verify: Some(2) });
    buffer.verify(&page(&[(2, "b")], 3));
    assert_eq!(buffer.resets, 0);
    assert!(buffer.take(page(&[(3, "c")], 3)));
    assert_eq!(seqs(&buffer), [1, 2, 3]);
    // Another log of the same length under a newer epoch: it starts over.
    let next = buffer.observe(&view(4, 3), 3);
    assert_eq!(next, Next { verify: Some(3) });
    buffer.verify(&page(&[(3, "other")], 3));
    assert_eq!(buffer.resets, 1);
    assert!(seqs(&buffer).is_empty());
    assert_eq!(buffer.have, 0);
}

#[test]
fn only_the_newest_events_are_kept_and_read() {
    let mut buffer = Buffer::new(0);
    let last = KEEP_MAX as u64 + 10;
    buffer.observe(&view(2, last), 1);
    assert_eq!(buffer.have, 10, "the read begins near the store's end");
    let all: Vec<(u64, &str)> = (11..=last).map(|seq| (seq, "x")).collect();
    assert!(buffer.take(page(&all, last)));
    assert_eq!(buffer.events.len(), KEEP_MAX);
    let reply = buffer.reply(0, 1);
    assert_eq!(reply["events"].as_array().unwrap().len(), REPLY_MAX);
    assert_eq!(reply["more"], true);
    assert_eq!(reply["events"][0]["seq"], 11);
}

#[test]
fn the_reply_says_how_far_behind_and_how_long_unheard() {
    let mut buffer = Buffer::new(100);
    let reply = buffer.reply(0, 600);
    assert_eq!(reply["projection"]["status"], "connecting");
    assert_eq!(reply["projection"]["lagMs"], 500);
    buffer.observe(&view(2, 5), 1_000);
    buffer.take(page(&[(1, "a"), (2, "b")], 5));
    buffer.failed("offline".into());
    let reply = buffer.reply(1, 4_000);
    let projection = &reply["projection"];
    assert_eq!(projection["status"], "reconnecting");
    assert_eq!(projection["lagMs"], 3_000);
    assert_eq!(projection["behind"], 3);
    assert_eq!(projection["error"], "offline");
    assert_eq!(projection["readOnly"], true);
    assert_eq!(reply["events"].as_array().unwrap().len(), 1, "only the events after `after`");
}
