use super::*;
use crate::wire::{Cursor, Stream};
use acpmux_book::index::replay_log;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::{Duration, Instant};
use tempfile::tempdir;

fn summary(id: &str, at: u64) -> Summary {
    let mut summary = Summary::new(id);
    summary.last_activity = at;
    summary
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

fn populated_index(prefix: &str, count: usize) -> SummaryIndex {
    (0..count).fold(SummaryIndex::new(), |index, n| {
        index.apply((n + 1) as u64, summary(&format!("{prefix}{n}"), n as u64))
    })
}

fn p95(samples: &[u128]) -> u128 {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let rank = ((sorted.len() * 95).saturating_add(99) / 100).saturating_sub(1);
    sorted[rank]
}

fn best_p95(rounds: &[Vec<u128>]) -> u128 {
    rounds.iter().map(|round| p95(round)).min().unwrap_or(1)
}

async fn measure_first_windows(index: SummaryIndex, sid: &str) -> Vec<Vec<u128>> {
    let (hub, writer) = Hub::new(index);
    let task = tokio::spawn(writer.run());
    let mut rounds = Vec::with_capacity(5);
    for round in 0..5 {
        let mut samples = Vec::with_capacity(200);
        for sample in 0..200 {
            let start = Instant::now();
            let mut sub = Sub::new(format!("{sid}-{round}-{sample}"), Stream::from("list"));
            sub.window = Some(20);
            let subscription = hub.subscribe(&sub).unwrap();
            let _: Window<Summary> = subscription.window.decode_json().unwrap();
            samples.push(start.elapsed().as_nanos().max(1));
            drop(subscription);
        }
        rounds.push(samples);
    }
    hub.close();
    task.await.unwrap().unwrap();
    rounds
}

fn measure_summary_changes(index: &SummaryIndex, chat_id: &str) -> Vec<Vec<u128>> {
    let mut rounds = Vec::with_capacity(5);
    for round in 0..5 {
        let (hub, mut writer) = Hub::new(index.clone());
        let _subscription =
            hub.subscribe(&Sub::new(format!("change-{round}"), Stream::from("list"))).unwrap();
        let mut samples = Vec::with_capacity(200);
        for sample in 0..200 {
            let start = Instant::now();
            writer.apply(summary(chat_id, (round * 5 + sample + 1) as u64)).unwrap();
            samples.push(start.elapsed().as_nanos().max(1));
        }
        rounds.push(samples);
    }
    rounds
}

#[test]
fn one_summary_change_publishes_without_walking_the_index() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(summary("a", 1)).unwrap();
    writer.apply(summary("b", 2)).unwrap();
    let event = writer.apply(summary("a", 3)).unwrap();
    assert_eq!(event.seq, 3);
    assert_eq!(hub.snapshot().len(), 2);
    let frame = hub.list_window(&Sub::new("sidebar", Stream::from("list"))).unwrap();
    let window: Window<Summary> = frame.decode_json().unwrap();
    assert_eq!(window.rows.first().map(|row| row.chat_id.as_str()), Some("a"));
    assert!(window.rows.len() <= DEFAULT_WINDOW_ROWS);
}

#[test]
fn list_window_is_bounded_and_rejects_other_streams() {
    let (hub, _) = Hub::new(SummaryIndex::new());
    assert!(matches!(
        hub.list_window(&Sub::new("chat", "chat:one")),
        Err(HubError::WrongStream(_))
    ));
    assert!(matches!(
        hub.list_window(&Sub::new("sidebar", "list").around(crate::wire::Anchor::End, 0)),
        Err(HubError::InvalidWindow)
    ));
}

#[test]
fn subscribe_rejects_oversized_window_before_registration() {
    let (hub, _) = Hub::new(SummaryIndex::new());
    let sub = Sub::new("oversized", "list").around(crate::wire::Anchor::End, u16::MAX);
    assert!(matches!(hub.subscribe(&sub), Err(HubError::InvalidWindow)));
    assert_eq!(hub.subscriber_count(), 0);
}

#[tokio::test(flavor = "current_thread")]
#[ignore = "timing gate; run in release with --ignored --nocapture"]
async fn list_window_gate_measures_running_subscriptions_at_both_sizes() {
    let small_rounds = measure_first_windows(populated_index("s", 20), "small").await;
    let god_rounds = measure_first_windows(populated_index("g", 11_000), "god").await;
    let small_p95 = best_p95(&small_rounds);
    let god_p95 = best_p95(&god_rounds);
    let all_god_samples = god_rounds.iter().flatten().copied().collect::<Vec<_>>();
    let all_god_p95 = p95(&all_god_samples);
    assert!(
        god_p95 <= small_p95.saturating_mul(12) / 10,
        "first window p95 grew beyond 1.2x: small={small_p95}ns god={god_p95}ns"
    );
    assert!(
        all_god_p95 <= small_p95.saturating_mul(2),
        "first window all-sample p95 exceeded 2x small p95: small={small_p95}ns god={all_god_p95}ns"
    );
    gate("v2.pr05.first_list_window", small_p95, god_p95, all_god_p95);

    let small_index = populated_index("s", 20);
    let god_index = populated_index("g", 11_000);
    let small_changes = measure_summary_changes(&small_index, "s0");
    let god_changes = measure_summary_changes(&god_index, "g0");
    let small_change_p95 = best_p95(&small_changes);
    let god_change_p95 = best_p95(&god_changes);
    let all_god_change_samples = god_changes.iter().flatten().copied().collect::<Vec<_>>();
    let all_god_change_p95 = p95(&all_god_change_samples);
    assert!(
        god_change_p95 <= small_change_p95.saturating_mul(37) / 10,
        "summary change p95 grew beyond 3.7x: small={small_change_p95}ns god={god_change_p95}ns"
    );
    assert!(
        all_god_change_p95 <= small_change_p95.saturating_mul(62) / 10,
        "summary change all-sample p95 exceeded 6.2x small p95: small={small_change_p95}ns god={all_god_change_p95}ns"
    );
    assert!(god_change_p95 <= 10_000, "summary change god p95 exceeded 10us: {god_change_p95}ns");
    gate("v2.pr05.summary_change", small_change_p95, god_change_p95, all_god_change_p95);
}

#[test]
fn opening_11k_rows_from_disk_reaches_first_window_under_200ms() {
    let dir = tempdir().unwrap();
    let log_path = dir.path().join("index.log");
    {
        let mut log = IndexLog::open(&log_path).unwrap();
        for n in 0..11_000 {
            log.append(summary(&format!("disk{n}"), n as u64)).unwrap();
        }
        log.sync().unwrap();
    }

    let start = Instant::now();
    let log = IndexLog::open(&log_path).unwrap();
    let index = replay_log(log.path(), SummaryIndex::new()).unwrap();
    assert_eq!(index.len(), 11_000);
    let (hub, _writer) = Hub::with_log(index, Some(log));
    let window = hub.list_window(&Sub::new("disk", "list")).unwrap();
    let _: Window<Summary> = window.decode_json().unwrap();
    let elapsed = start.elapsed();
    assert!(elapsed < Duration::from_millis(200), "disk startup took {elapsed:?}");
}

#[tokio::test(flavor = "current_thread")]
async fn subscribe_recv_and_run_deliver_summary_then_removal() {
    let (hub, writer) = Hub::new(SummaryIndex::new());
    let task = tokio::spawn(writer.run());
    let subscription = hub.subscribe(&Sub::new("live", "list")).unwrap();
    hub.submit(summary("live-chat", 1)).unwrap();
    match subscription.receiver.recv().await.unwrap() {
        ListItem::Summary(event) => assert_eq!(event.summary.chat_id, "live-chat"),
        other => panic!("expected summary, got {other:?}"),
    }
    hub.remove("local", "live-chat").unwrap();
    match subscription.receiver.recv().await.unwrap() {
        ListItem::Gone { chat_id, .. } => assert_eq!(chat_id, "live-chat"),
        other => panic!("expected removal, got {other:?}"),
    }
    hub.close();
    task.await.unwrap().unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn replay_does_not_replace_newer_live_item_for_same_chat() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(summary("same", 1)).unwrap();
    let subscription = hub.subscribe(&Sub::new("resume", "list").from_cursor(0)).unwrap();
    writer.apply(summary("same", 2)).unwrap();
    match subscription.receiver.recv().await.unwrap() {
        ListItem::Summary(event) => assert_eq!(event.seq, 1),
        other => panic!("expected replayed summary, got {other:?}"),
    }
    match subscription.receiver.recv().await.unwrap() {
        ListItem::Summary(event) => assert_eq!(event.seq, 2),
        other => panic!("expected newer summary, got {other:?}"),
    }
    subscription.receiver.reposition(2);
    let state = subscription.receiver.subscriber.state.lock().unwrap();
    assert!(!state.ended);
    assert_eq!(state.cursor, 2);
}

#[test]
fn cursor_ahead_of_index_gets_a_fresh_current_window() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(summary("current", 1)).unwrap();
    let subscription = hub.subscribe(&Sub::new("ahead", "list").from_cursor(Cursor(10))).unwrap();
    let window: Window<Summary> = subscription.window.decode_json().unwrap();
    assert_eq!(window.cursor, 1);
    assert!(!subscription.receiver.subscriber.state.lock().unwrap().ended);
}

#[test]
fn dropping_a_list_receiver_unregisters_the_subscriber() {
    let (hub, _) = Hub::new(SummaryIndex::new());
    let subscription = hub.subscribe(&Sub::new("drop", "list")).unwrap();
    assert_eq!(hub.subscriber_count(), 1);
    drop(subscription);
    assert_eq!(hub.subscriber_count(), 0);
}

#[test]
fn submit_coalesces_latest_summary_per_chat_without_an_item_cap() {
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    for at in 0..11_000 {
        hub.submit(summary("same", at)).unwrap();
    }
    let batch = hub.updates.take_batch();
    assert_eq!(batch.len(), 1);
    match &batch[0].1 {
        PendingUpdate::Summary { summary, .. } => assert_eq!(summary.last_activity, 10_999),
        PendingUpdate::Gone { .. } => panic!("summary slot was replaced by a removal"),
        PendingUpdate::Origin { .. } | PendingUpdate::Takeover { .. } => {
            panic!("origin update occupied summary slot")
        }
    }
}

#[test]
fn removal_publishes_a_gone_change_and_removes_the_row() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(summary("gone", 1)).unwrap();
    assert!(writer.remove("local", "gone").unwrap());
    assert!(hub.snapshot().get("gone").is_none());
    assert!(!writer.remove("local", "gone").unwrap());
}

#[test]
fn source_ownership_refuses_cross_source_updates_until_takeover() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let mut row = summary("remote", 1);
    row.origin = "peer".into();
    writer.apply_from(Source::Mirror, row.clone()).unwrap();
    assert!(matches!(
        writer.apply_from(Source::V1, row.clone()),
        Err(HubError::SourceRefused { .. })
    ));
    writer.takeover("peer", Source::V1).unwrap();
    writer.apply_from(Source::V1, row).unwrap();
    assert!(hub.snapshot().get_row(&RowKey::new("peer", "remote")).is_some());
    assert!(refused_source_submits() > 0);
}

#[test]
fn remote_close_emits_summary_but_is_absent_from_index_and_replay() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("index.log");
    let log = IndexLog::open(&path).unwrap();
    let (hub, mut writer) = Hub::with_log(SummaryIndex::new(), Some(log));
    let mut row = summary("remote", 1);
    row.origin = "peer".into();
    writer.apply_from(Source::V1, row).unwrap();
    let mut closed = summary("remote", 2);
    closed.origin = "peer".into();
    closed.state = "closed".into();
    let event = writer.apply_from(Source::V1, closed).unwrap();
    assert_eq!(event.summary.state, "closed");
    assert!(hub.snapshot().get_row(&RowKey::new("peer", "remote")).is_none());
    let restored = replay_log(&path, SummaryIndex::new()).unwrap();
    assert!(restored.get_row(&RowKey::new("peer", "remote")).is_none());
}

#[test]
fn origin_state_is_one_record_and_removed_origin_hides_rows() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    assert!(writer.origin("peer", OriginState::Down, 10).unwrap());
    assert!(!writer.origin("peer", OriginState::Down, 10).unwrap());
    assert!(writer.origin("peer", OriginState::Stale, 20).unwrap());
    let mut row = summary("remote", 1);
    row.origin = "peer".into();
    writer.apply_from(Source::V1, row).unwrap();
    writer.origin("peer", OriginState::Removed, 30).unwrap();
    assert!(hub.snapshot().iter().next().is_none());
    let window: Window<Summary> =
        hub.list_window(&Sub::new("origin", "list")).unwrap().decode_json().unwrap();
    assert!(window.rows.is_empty());
    assert_eq!(window.origins.len(), 1);
    assert_eq!(window.origins[0].state, OriginState::Removed);
}
