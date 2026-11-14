use super::*;
use acpmux_book::index::{ChangedRows, SortedSnapshot};
use std::collections::BTreeSet;
use std::fs;
#[cfg(target_os = "linux")]
use std::path::Path;

fn remote(id: impl Into<String>, activity: u64) -> Summary {
    let mut row = Summary::new(id);
    row.origin = "peer".into();
    row.state = "running".into();
    row.last_activity = activity;
    row
}

fn seed(writer: &mut HubWriter, count: usize) {
    writer.origin("peer", OriginState::Connected, 1).unwrap();
    for n in 0..count {
        writer.apply(remote(format!("old-{n:04}"), n as u64 + 1)).unwrap();
    }
}

fn returned(n: usize) -> Summary {
    // Ten rows repeat the exact bytes of their previous life. They must still
    // be appended, rather than swallowed by the equality optimization.
    if n < 10 {
        remote(format!("old-{n:04}"), n as u64 + 1)
    } else {
        remote(format!("new-{n:04}"), n as u64 + 10_000)
    }
}

fn queue_return(hub: &Hub, count: usize) {
    hub.origin("peer", OriginState::Connected, 3).unwrap();
    for n in 0..count {
        hub.submit(returned(n)).unwrap();
    }
}

fn drive(writer: &mut HubWriter, turns: usize) {
    for _ in 0..turns {
        writer.process_batch();
    }
}

fn ids(hub: &Hub) -> BTreeSet<String> {
    hub.snapshot().merged_rows().map(|row| row.unwrap().chat_id.clone()).collect()
}

fn returned_ids(count: usize) -> BTreeSet<String> {
    (0..count).map(|n| returned(n).chat_id).collect()
}

fn changes(subscription: &ListSubscription) -> Vec<ListItem> {
    let mut items = Vec::new();
    while let Some(item) = subscription.receiver.try_next() {
        items.push(item);
        assert!(items.len() <= 20_000, "receiver failed to advance");
    }
    items
}

fn assert_origin(item: ListItem, state: OriginState, since: u64) {
    match item {
        ListItem::Origin { origin, .. } => {
            assert_eq!(origin.id, "peer");
            assert_eq!(origin.state, state);
            assert_eq!(origin.since, since);
        }
        other => panic!("expected origin {state:?}, got {other:?}"),
    }
}

#[test]
fn origin_ring_round_trip_preserves_flat_fields_and_extra() {
    let mut history = History::new();
    let expected = Origin {
        id: "peer\\escaped\"id".into(),
        state: OriginState::Stale,
        since: 123,
        extra: Some(serde_json::json!({"future": [1, "value"]})),
    };
    history.append(&ListItem::Origin { seq: 17, origin: expected.clone() }).unwrap();
    let bytes = history.after(16, 17).unwrap();
    let wire: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(wire.get("id").and_then(serde_json::Value::as_str), Some(expected.id.as_str()));
    assert!(wire.get("origin").is_none());
    let decoded = history::decode(bytes).unwrap();
    match decoded.into_iter().next().unwrap() {
        ListItem::Origin { seq, origin } => {
            assert_eq!(seq, 17);
            assert_eq!(origin, expected);
        }
        other => panic!("origin did not round trip: {other:?}"),
    }
}

#[test]
fn origin_states_cross_the_resume_ring_and_append_exactly_three_records() {
    let directory = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    let subscription = hub.subscribe(&Sub::new("origin-states", "list")).unwrap();
    for (state, since) in
        [(OriginState::Down, 10), (OriginState::Stale, 20), (OriginState::Connected, 30)]
    {
        hub.origin("peer", state, since).unwrap();
        writer.process_batch();
        assert_origin(subscription.receiver.try_next().unwrap(), state, since);
        assert!(subscription.receiver.try_next().is_none());
    }
    assert_eq!(hub.snapshot().seq(), 3);
    assert_eq!(writer.log.as_ref().unwrap().next_seq(), 3);
    assert_eq!(writer.history.lock().unwrap().len(), 3);
    let bytes = writer.log.as_ref().unwrap().offset();
    hub.origin("peer", OriginState::Connected, 900).unwrap();
    writer.process_batch();
    assert_eq!(hub.snapshot().origin("peer").unwrap().since, 30);
    assert_eq!(hub.snapshot().seq(), 3);
    assert_eq!(writer.log.as_ref().unwrap().offset(), bytes);
    assert!(subscription.receiver.try_next().is_none());
    drop((subscription, hub, writer));
    let (reopened, writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    assert_eq!(reopened.snapshot().seq(), 3);
    assert_eq!(reopened.snapshot().origin("peer").unwrap().since, 30);
    assert_eq!(writer.log.as_ref().unwrap().offset(), bytes);
}

#[test]
fn the_257th_origin_is_refused_through_the_queue_and_direct_writer() {
    for queued in [false, true] {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        for n in 0..256 {
            let id = format!("peer-{n:03}");
            if queued {
                hub.origin(&id, OriginState::Connected, 1).unwrap();
            } else {
                writer.origin(&id, OriginState::Connected, 1).unwrap();
            }
        }
        writer.process_batch();
        assert_eq!(hub.snapshot().origins().count(), 256);
        let refused = refused_origins();
        if queued {
            hub.origin("overflow", OriginState::Down, 2).unwrap();
            writer.process_batch();
        } else {
            assert!(matches!(
                writer.origin("overflow", OriginState::Down, 2),
                Err(HubError::OriginLimit)
            ));
        }
        assert!(refused_origins() > refused);
        assert_eq!(hub.snapshot().seq(), 256);
        assert!(hub.snapshot().origin("overflow").is_none());
    }
}

#[test]
fn row_sources_are_bounded_without_charging_local_rows_an_origin_slot() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(Summary::new("local-row")).unwrap();
    for n in 0..256 {
        let mut row = remote("row", 1);
        row.origin = format!("peer-{n:03}");
        writer.apply_from(Source::V1, row).unwrap();
    }
    let refused = refused_origins();
    let mut overflow = remote("overflow", 2);
    overflow.origin = "overflow-origin".into();
    hub.submit_from(Source::V1, overflow).unwrap();
    writer.process_batch();
    assert!(refused_origins() > refused);
    assert_eq!(hub.snapshot().len(), 257);
    assert!(hub.snapshot().get("local-row").is_some());
    assert!(hub.snapshot().get_row(&RowKey::new("overflow-origin", "overflow")).is_none());
    assert!(writer.takeover("local", Source::Mirror).is_err());
    assert!(writer.takeover("overflow-origin", Source::Mirror).is_err());
}

#[test]
fn queued_wrong_source_submit_and_remove_leave_the_index_unchanged() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.takeover("peer", Source::Mirror).unwrap();
    writer.apply_from(Source::Mirror, remote("row", 1)).unwrap();
    let subscription = hub.subscribe(&Sub::new("sources", "list")).unwrap();
    let seq = hub.snapshot().seq();
    let refused = refused_source_submits();
    hub.submit_from(Source::V1, remote("row", 2)).unwrap();
    writer.process_batch();
    hub.remove_from(Source::V1, "peer", "row").unwrap();
    writer.process_batch();
    assert!(refused_source_submits() >= refused + 2);
    assert_eq!(hub.snapshot().seq(), seq);
    assert_eq!(hub.snapshot().get_row(&RowKey::new("peer", "row")).unwrap().last_activity, 1);
    assert!(subscription.receiver.try_next().is_none());
    hub.takeover("peer", Source::V1).unwrap();
    writer.process_batch();
    hub.submit_from(Source::V1, remote("row", 2)).unwrap();
    writer.process_batch();
    assert_eq!(hub.snapshot().get_row(&RowKey::new("peer", "row")).unwrap().last_activity, 2);
}

#[test]
fn a_wrong_producer_cannot_overwrite_the_owners_same_key_pending_update() {
    for takeover in [false, true] {
        for wrong_remove in [false, true] {
            let (hub, mut writer) = Hub::new(SummaryIndex::new());
            seed(&mut writer, if takeover { 500 } else { 1 });
            let (owner, wrong) = if takeover {
                writer.origin("peer", OriginState::Removed, 2).unwrap();
                hub.takeover("peer", Source::Mirror).unwrap();
                hub.origin("peer", OriginState::Connected, 3).unwrap();
                (Source::Mirror, Source::V1)
            } else {
                (Source::V1, Source::Mirror)
            };
            let refused = refused_source_submits();
            let mut rightful = remote("same-key", 4);
            rightful.title = "rightful pending row".into();
            hub.submit_from(owner, rightful.clone()).unwrap();
            if wrong_remove {
                hub.remove_from(wrong, "peer", "same-key").unwrap();
            } else {
                let mut invalid = rightful.clone();
                invalid.title = "wrong producer overwrote queue slot".into();
                hub.submit_from(wrong, invalid).unwrap();
            }
            // Both producers arrive before the writer can check ownership.
            // During removal, the queued takeover also precedes the held rows.
            writer.process_batch();
            drive(&mut writer, 8);
            assert!(refused_source_submits() > refused);
            let snapshot = hub.snapshot();
            let row = snapshot.get_row(&rightful.key()).unwrap();
            assert_eq!(row.title, rightful.title);
            assert_eq!(row.last_activity, rightful.last_activity);
            if takeover {
                assert_eq!(snapshot.len(), 1);
                assert_eq!(snapshot.origin("peer").unwrap().state, OriginState::Connected);
            }
        }
    }
}

#[test]
fn removing_500_rows_publishes_one_op_then_cleans_two_bounded_batches() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    seed(&mut writer, 500);
    let subscription = hub.subscribe(&Sub::new("remove", "list")).unwrap();
    writer.origin("peer", OriginState::Removed, 2).unwrap();
    assert_eq!(hub.snapshot().len(), 500, "the origin op must not walk its rows");
    assert!(hub.snapshot().iter().next().is_none());
    let window: Window<Summary> =
        hub.list_window(&Sub::new("hidden", "list")).unwrap().decode_json().unwrap();
    assert!(window.rows.is_empty());
    assert_origin(subscription.receiver.try_next().unwrap(), OriginState::Removed, 2);
    writer.process_batch();
    assert_eq!(hub.snapshot().len(), 244);
    writer.process_batch();
    assert_eq!(hub.snapshot().len(), 0);
    assert!(subscription.receiver.try_next().is_none());
    let seq = hub.snapshot().seq();
    assert!(!writer.origin("never-held", OriginState::Removed, 4).unwrap());
    assert_eq!(hub.snapshot().seq(), seq);
}

#[test]
fn a_removed_record_and_takeover_never_replace_each_others_queue_slot() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    seed(&mut writer, 500);
    let subscription = hub.subscribe(&Sub::new("takeover", "list")).unwrap();
    hub.origin("peer", OriginState::Removed, 2).unwrap();
    hub.takeover("peer", Source::Mirror).unwrap();
    drive(&mut writer, 6);
    let mut items = changes(&subscription).into_iter();
    assert_origin(items.next().unwrap(), OriginState::Removed, 2);
    assert!(items.next().is_none());
    assert!(ids(&hub).is_empty());
    assert!(matches!(
        writer.apply_from(Source::V1, remote("new", 1)),
        Err(HubError::SourceRefused { .. })
    ));
    writer.apply_from(Source::Mirror, remote("new", 1)).unwrap();
    assert_eq!(ids(&hub), BTreeSet::from(["new".to_owned()]));
}

#[test]
fn queued_origin_removal_survives_later_state_replacements() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.origin("peer", OriginState::Connected, 1).unwrap();
    let old = remote("old", 1);
    writer.apply(old.clone()).unwrap();
    writer.process_batch();

    hub.submit(old).unwrap();
    hub.origin("peer", OriginState::Removed, 2).unwrap();
    hub.origin("peer", OriginState::Connected, 3).unwrap();
    hub.origin("peer", OriginState::Down, 4).unwrap();
    writer.process_batch();
    writer.process_batch();

    assert!(hub.snapshot().get_row(&RowKey::new("peer", "old")).is_none());
    assert_eq!(hub.snapshot().origin("peer").unwrap().state, OriginState::Down);
}

#[test]
fn a_row_named_like_origin_metadata_has_a_separate_queue_slot() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    seed(&mut writer, 500);
    let mut row = remote("peer", 1);
    row.origin = "origin".into();
    // In the former queue all three were RowKey("origin", "peer").
    hub.submit(row).unwrap();
    hub.origin("peer", OriginState::Removed, 2).unwrap();
    hub.takeover("peer", Source::Mirror).unwrap();
    drive(&mut writer, 8);
    assert_eq!(hub.snapshot().origin("peer").unwrap().state, OriginState::Removed);
    assert!(hub.snapshot().get_row(&RowKey::new("origin", "peer")).is_some());
    assert_eq!(hub.snapshot().len(), 1);
    assert!(matches!(
        writer.apply_from(Source::V1, remote("later", 3)),
        Err(HubError::SourceRefused { .. })
    ));
    writer.apply_from(Source::Mirror, remote("later", 3)).unwrap();
    assert!(hub.snapshot().get_row(&RowKey::new("peer", "later")).is_some());
}

#[cfg(target_os = "linux")]
#[test]
fn append_failure_retries_keep_the_source_and_respect_a_later_removed_record() {
    const CHILD: &str = "V2_ORIGIN_APPEND_FAILURE_FIXTURE";
    const MODE: &str = "V2_ORIGIN_APPEND_FAILURE_MODE";
    if let Some(directory) = std::env::var_os(CHILD) {
        let (hub, mut writer) = Hub::open(Path::new(&directory), 101, || 7).unwrap();
        writer.takeover("peer", Source::Mirror).unwrap();
        let subscription = hub.subscribe(&Sub::new("failed-append", "list")).unwrap();
        let seq = hub.snapshot().seq();
        let before = writer.log.as_ref().unwrap().offset();
        let remove_origin = std::env::var(MODE).unwrap() == "removed";
        let mut replacement = remote("row", 4);
        replacement.title = "failed version".into();
        assert!(writer.apply_from(Source::Mirror, replacement.clone()).is_err());
        replacement.title = "latest version".into();
        assert!(writer.apply_from(Source::Mirror, replacement).is_err());
        if remove_origin {
            assert!(writer.origin("peer", OriginState::Removed, 5).is_err());
        } else {
            assert!(writer.remove_from(Source::Mirror, "peer", "gone").is_err());
            assert!(writer.origin("peer", OriginState::Down, 5).is_err());
        }
        assert_eq!(hub.snapshot().seq(), seq);
        assert_eq!(writer.log.as_ref().unwrap().offset(), before);
        assert!(subscription.receiver.try_next().is_none());
        let (source, record) = writer.retry_log.get(&RowKey::new("peer", "row")).unwrap();
        assert_eq!(*source, Source::Mirror);
        assert_eq!(record.summary.title, "latest version");
        assert_eq!(writer.origins.retry.get("peer").unwrap().since, 5);

        // The shell set only this child process's soft limit; restore it to
        // its unchanged hard limit so the exact same writer retries real I/O.
        // resource.prlimit avoids unsafe Rust and alters only our own PID.
        let restored = std::process::Command::new("python3")
            .args([
                "-c",
                "import resource,sys; pid=int(sys.argv[1]); soft,hard=resource.prlimit(pid,resource.RLIMIT_FSIZE); resource.prlimit(pid,resource.RLIMIT_FSIZE,(hard,hard))",
            ])
            .arg(std::process::id().to_string())
            .status()
            .unwrap();
        assert!(restored.success());
        writer.sync_batch().unwrap();
        drive(&mut writer, 8);
        assert!(writer.retry_log.is_empty());
        assert!(writer.origins.retry.is_empty());
        if remove_origin {
            assert!(ids(&hub).is_empty(), "a failed row predating Removed entered the next life");
            let mut items = changes(&subscription).into_iter();
            assert_origin(items.next().unwrap(), OriginState::Removed, 5);
            assert!(items.next().is_none());
            assert_eq!(hub.snapshot().seq(), seq + 1);
        } else {
            assert_eq!(
                hub.snapshot().get_row(&RowKey::new("peer", "row")).unwrap().title,
                "latest version"
            );
            assert!(hub.snapshot().get_row(&RowKey::new("peer", "gone")).is_none());
            assert_eq!(hub.snapshot().origin("peer").unwrap().state, OriginState::Down);
            assert_eq!(hub.snapshot().seq(), seq + 3);
            let items = changes(&subscription);
            assert_eq!(items.len(), 3);
            assert_eq!(items.iter().filter(|item| matches!(item, ListItem::Summary(_))).count(), 1);
            assert_eq!(
                items.iter().filter(|item| matches!(item, ListItem::Gone { .. })).count(),
                1
            );
            assert_eq!(
                items.iter().filter(|item| matches!(item, ListItem::Origin { .. })).count(),
                1
            );
        }
        let expected = ids(&hub);
        let expected_seq = hub.snapshot().seq();
        drop((subscription, hub, writer));
        let (hub, _) = Hub::open(Path::new(&directory), 101, || 7).unwrap();
        assert_eq!(hub.snapshot().seq(), expected_seq);
        assert_eq!(ids(&hub), expected);
        return;
    }

    for mode in ["source", "removed"] {
        let directory = tempfile::tempdir().unwrap();
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        writer.origin("peer", OriginState::Connected, 1).unwrap();
        writer.apply(remote("row", 2)).unwrap();
        writer.apply(remote("gone", 3)).unwrap();
        writer.sync_batch().unwrap();
        drop((hub, writer));
        let status = std::process::Command::new("bash")
            .args(["-c", "trap '' XFSZ; ulimit -S -f 0; exec \"$@\"", "origin-append-failure"])
            .arg(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "hub::origin_tests::append_failure_retries_keep_the_source_and_respect_a_later_removed_record",
                "--nocapture",
            ])
            .env(CHILD, directory.path())
            .env(MODE, mode)
            .status()
            .unwrap();
        assert!(status.success(), "append failure {mode} child: {status}");
    }
}

#[test]
fn a_returning_origin_keeps_all_new_rows_including_identical_old_keys() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    seed(&mut writer, 500);
    let subscription = hub.subscribe(&Sub::new("return", "list")).unwrap();
    hub.origin("peer", OriginState::Removed, 2).unwrap();
    writer.process_batch();
    assert_origin(subscription.receiver.try_next().unwrap(), OriginState::Removed, 2);
    queue_return(&hub, 50);
    drive(&mut writer, 6);
    assert_eq!(ids(&hub), returned_ids(50));
    let window: Window<Summary> =
        hub.list_window(&Sub::new("returned", "list")).unwrap().decode_json().unwrap();
    assert_eq!(window.rows.len(), 50);
    let mut items = changes(&subscription).into_iter();
    assert_origin(items.next().unwrap(), OriginState::Connected, 3);
    let summaries: Vec<_> = items
        .map(|item| match item {
            ListItem::Summary(event) => event.summary.chat_id.clone(),
            other => panic!("return emitted a non-summary: {other:?}"),
        })
        .collect();
    assert_eq!(summaries.len(), 50);
    assert_eq!(summaries.into_iter().collect::<BTreeSet<_>>(), returned_ids(50));
}

#[test]
fn a_second_removed_while_leaving_discards_the_intermediate_life() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    seed(&mut writer, 500);

    // The first removal is published, but its bounded cleanup still has work left.
    hub.origin("peer", OriginState::Removed, 2).unwrap();
    writer.process_batch();
    assert!(hub.snapshot().is_origin_leaving("peer"));

    // A reconnect and rows accepted during that cleanup belong to a short-lived life.
    hub.origin("peer", OriginState::Connected, 3).unwrap();
    for n in 0..50 {
        hub.submit(returned(n)).unwrap();
    }

    // A second removal is a lifecycle cut: it must clear the held reconnect and rows,
    // rather than releasing them after the first life finishes.
    hub.origin("peer", OriginState::Removed, 4).unwrap();
    drive(&mut writer, 12);

    assert!(ids(&hub).is_empty(), "rows from the intermediate life were resurrected");
    assert_eq!(hub.snapshot().origin("peer").unwrap().state, OriginState::Removed);
}

#[test]
fn held_updates_beyond_one_batch_are_not_discarded_or_starved() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    seed(&mut writer, 3000);
    hub.origin("peer", OriginState::Removed, 2).unwrap();
    writer.process_batch();
    writer.origin("peer", OriginState::Connected, 3).unwrap();
    for n in 0..600 {
        writer.apply_from(Source::V1, returned(n)).unwrap();
    }
    let mut latest = returned(25);
    latest.title = "latest held value".into();
    writer.apply_from(Source::V1, latest).unwrap();
    hub.submit(Summary::new("independent")).unwrap();
    drive(&mut writer, 4);
    assert!(
        hub.snapshot().get("independent").is_some(),
        "one leaving origin stalled another origin"
    );
    drive(&mut writer, 20);
    let mut expected = returned_ids(600);
    expected.insert("independent".into());
    assert_eq!(ids(&hub), expected);
    assert_eq!(hub.snapshot().get_row(&returned(25).key()).unwrap().title, "latest held value");
}

#[test]
fn a_newer_held_row_or_gone_invalidates_an_older_retry_before_sync() {
    for gone in [false, true] {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        seed(&mut writer, 500);
        writer.origin("peer", OriginState::Removed, 2).unwrap();
        writer.origin("peer", OriginState::Connected, 3).unwrap();
        for n in 0..600 {
            writer.apply_from(Source::V1, returned(n)).unwrap();
        }
        writer.advance_origins(256);
        writer.advance_origins(256);
        assert!(!hub.snapshot().is_origin_leaving("peer"));
        assert!(writer.holds_origin("peer"), "the held backlog must exceed a turn");

        // Model a failed append of a released row while other held rows remain.
        let mut old = returned(0);
        old.title = "older failed append".into();
        let key = old.key();
        assert!(hub.snapshot().get_row(&key).is_some());
        writer.retry_log.insert(
            key.clone(),
            (
                Source::V1,
                acpmux_book::index::IndexRecord {
                    seq: hub.snapshot().seq() + 1,
                    origin: old.origin.clone(),
                    chat_id: old.chat_id.clone(),
                    summary: old,
                    gone: false,
                },
            ),
        );
        if gone {
            writer.remove_from(Source::V1, &key.origin, &key.chat_id).unwrap();
        } else {
            let mut newer = returned(0);
            newer.title = "newest accepted held row".into();
            writer.apply_from(Source::V1, newer).unwrap();
        }
        assert!(
            !writer.retry_log.contains_key(&key),
            "accepting the newer held update must invalidate the old retry before sync"
        );
        writer.sync_batch().unwrap();
        drive(&mut writer, 8);
        if gone {
            assert!(hub.snapshot().get_row(&key).is_none());
            assert_eq!(hub.snapshot().len(), 599);
        } else {
            assert_eq!(hub.snapshot().get_row(&key).unwrap().title, "newest accepted held row");
            assert_eq!(hub.snapshot().len(), 600);
        }
    }
}

#[test]
fn wrong_source_cannot_replace_a_rightful_held_row_or_gone_after_takeover() {
    for takeover in [false, true] {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        seed(&mut writer, 500);
        writer.origin("peer", OriginState::Removed, 2).unwrap();
        writer.origin("peer", OriginState::Connected, 3).unwrap();
        let (owner, wrong) = if takeover {
            writer.takeover("peer", Source::Mirror).unwrap();
            (Source::Mirror, Source::V1)
        } else {
            (Source::V1, Source::Mirror)
        };
        for n in 0..600 {
            writer.apply_from(owner, returned(n)).unwrap();
        }
        writer.remove_from(owner, "peer", &returned(26).chat_id).unwrap();
        let refused = refused_source_submits();
        let mut invalid = returned(25);
        invalid.title = "wrong source".into();
        assert!(matches!(writer.apply_from(wrong, invalid), Err(HubError::SourceRefused { .. })));
        assert!(matches!(
            writer.remove_from(wrong, "peer", &returned(25).chat_id),
            Err(HubError::SourceRefused { .. })
        ));
        assert!(matches!(
            writer.apply_from(wrong, returned(26)),
            Err(HubError::SourceRefused { .. })
        ));
        assert!(refused_source_submits() >= refused + 3);
        drive(&mut writer, 8);
        assert_eq!(hub.snapshot().get_row(&returned(25).key()).unwrap().title, returned(25).title);
        assert!(hub.snapshot().get_row(&returned(26).key()).is_none());
        assert_eq!(hub.snapshot().len(), 599);
    }
}

#[test]
fn held_updates_claim_an_unregistered_replayed_origins_source() {
    for owner in [Source::V1, Source::Mirror] {
        let original = remote("replayed", 1);
        let key = original.key();
        let (hub, mut writer) = Hub::new(SummaryIndex::new().apply(1, original));
        assert!(hub.sources.load().is_empty());
        writer.origin("peer", OriginState::Removed, 2).unwrap();
        writer.origin("peer", OriginState::Connected, 3).unwrap();
        assert!(matches!(
            writer.apply_from(Source::Local, remote("replayed", 4)),
            Err(HubError::SourceRefused { .. })
        ));
        let rightful = remote("replayed", 5);
        writer.apply_from(owner, rightful.clone()).unwrap();
        for wrong in [Source::Local, Source::V1, Source::Mirror] {
            if wrong == owner {
                continue;
            }
            assert!(matches!(
                writer.apply_from(wrong, remote("replayed", 6)),
                Err(HubError::SourceRefused { .. })
            ));
            assert!(matches!(
                writer.remove_from(wrong, "peer", "replayed"),
                Err(HubError::SourceRefused { .. })
            ));
        }
        drive(&mut writer, 4);
        assert!(hub.snapshot().get_row(&key).unwrap().same_content(&rightful));
    }
}

#[test]
fn a_leaving_origin_holds_at_most_16384_distinct_rows_but_accepts_replacements() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    seed(&mut writer, 500);
    writer.origin("peer", OriginState::Removed, 2).unwrap();
    let seq = hub.snapshot().seq();
    for n in 0..16_384 {
        writer.apply_from(Source::V1, remote(format!("held-{n:05}"), 4)).unwrap();
    }
    let refused = refused_held_rows();
    assert!(writer.apply_from(Source::V1, remote("overflow", 4)).is_err());
    assert!(refused_held_rows() > refused);
    writer.apply_from(Source::V1, remote("held-00000", 5)).unwrap();
    assert_eq!(hub.snapshot().seq(), seq, "holding updates must not append them yet");
}

#[tokio::test(flavor = "current_thread")]
async fn closing_the_hub_finishes_removal_and_held_updates_without_another_wake() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    seed(&mut writer, 1000);
    hub.origin("peer", OriginState::Removed, 2).unwrap();
    writer.process_batch();
    queue_return(&hub, 600);
    hub.close();
    tokio::time::timeout(std::time::Duration::from_secs(10), writer.run()).await.unwrap().unwrap();
    assert_eq!(ids(&hub), returned_ids(600));
}

#[test]
fn restart_at_each_removal_stage_never_restores_the_previous_life() {
    for cleanup_turns in 0..=2 {
        let directory = tempfile::tempdir().unwrap();
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        seed(&mut writer, 500);
        writer.origin("peer", OriginState::Removed, 2).unwrap();
        drive(&mut writer, cleanup_turns);
        writer.sync_batch().unwrap();
        let seq = hub.snapshot().seq();
        drop((hub, writer));
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        assert_eq!(hub.snapshot().seq(), seq);
        assert!(ids(&hub).is_empty());
        assert_eq!(hub.snapshot().len(), 0, "replay must finish physical deletion");
        queue_return(&hub, 50);
        drive(&mut writer, 6);
        assert_eq!(ids(&hub), returned_ids(50));
        let bytes = writer.log.as_ref().unwrap().offset();
        let seq = hub.snapshot().seq();
        drop((hub, writer));
        let (hub, writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        assert_eq!(ids(&hub), returned_ids(50));
        assert_eq!(hub.snapshot().seq(), seq);
        assert_eq!(writer.log.as_ref().unwrap().offset(), bytes);
    }
}

#[test]
fn origins_and_since_survive_compaction_and_idempotent_second_start() {
    let directory = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    for n in 0..256 {
        hub.origin(&format!("peer-{n:03}"), OriginState::Connected, n + 1).unwrap();
    }
    writer.process_batch();
    let expected: Vec<_> = hub.snapshot().origins().cloned().collect();
    writer
        .log
        .as_mut()
        .unwrap()
        .compact(directory.path().join("index.snap"), &hub.snapshot())
        .unwrap();
    assert_eq!(writer.log.as_ref().unwrap().offset(), 0);
    drop((hub, writer));
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    assert_eq!(hub.snapshot().origins().cloned().collect::<Vec<_>>(), expected);
    for origin in &expected {
        hub.origin(&origin.id, origin.state, origin.since + 1000).unwrap();
    }
    writer.process_batch();
    assert_eq!(hub.snapshot().seq(), 256);
    assert_eq!(writer.log.as_ref().unwrap().offset(), 0);
    assert_eq!(hub.snapshot().origins().cloned().collect::<Vec<_>>(), expected);
}

#[test]
fn late_compaction_install_cannot_revive_rows_of_an_earlier_origin_life() {
    let directory = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    seed(&mut writer, 500);
    let captured = hub.snapshot();
    let plan = writer.log.as_mut().unwrap().rotate(captured.seq()).unwrap();
    hub.origin("peer", OriginState::Removed, 2).unwrap();
    writer.process_batch();
    queue_return(&hub, 50);
    drive(&mut writer, 6);
    assert_eq!(ids(&hub), returned_ids(50));
    let compacted = plan.run(captured).unwrap();
    let current = hub.snapshot();
    let changed: ChangedRows = (0..50).map(|n| returned(n).key()).collect();
    let (installed, _) = current.with_compacted_snapshot(compacted.snapshot, changed);
    writer.published.store(Arc::new(installed));
    writer.start_hydration();
    drive(&mut writer, 4);
    assert_eq!(ids(&hub), returned_ids(50));
    let window: Window<Summary> =
        hub.list_window(&Sub::new("late-snapshot", "list")).unwrap().decode_json().unwrap();
    // Hidden physical candidates still consume the bounded page. Follow its
    // continuation instead of mistaking a partial first window for lost rows.
    let index = hub.snapshot();
    let mut anchor = None;
    let mut seen = BTreeSet::new();
    for _ in 0..12 {
        let page = index
            .read_page(
                anchor.as_ref(),
                ReadSide::After,
                false,
                100,
                crate::wire::MAX_PAGE_BYTES,
                None,
            )
            .unwrap();
        seen.extend(page.rows.iter().map(|row| row.chat_id.clone()));
        if !page.has_after {
            break;
        }
        assert_ne!(anchor, page.after_key);
        anchor = page.after_key;
    }
    assert_eq!(seen, returned_ids(50), "all returned rows must remain reachable");
    assert!(window.rows.iter().all(|row| returned_ids(50).contains(&row.chat_id)));
    drop((hub, writer));
    let (hub, _) = Hub::open(directory.path(), 101, || 7).unwrap();
    assert_eq!(ids(&hub), returned_ids(50));
}

#[test]
fn an_unknown_remote_close_does_not_append_when_an_unrelated_snapshot_exists() {
    let directory = tempfile::tempdir().unwrap();
    SortedSnapshot::write(
        directory.path().join("index.snap"),
        &SummaryIndex::new().apply(1, remote("other", 1)),
    )
    .unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    let subscription = hub.subscribe(&Sub::new("unknown-close", "list")).unwrap();
    let before = writer.log.as_ref().unwrap().offset();
    let seq = hub.snapshot().seq();
    let mut closed = remote("unknown", 2);
    closed.state = "closed".into();
    writer.apply_from(Source::V1, closed).unwrap();
    writer.process_batch();
    assert_eq!(hub.snapshot().seq(), seq);
    assert_eq!(writer.log.as_ref().unwrap().offset(), before);
    assert!(subscription.receiver.try_next().is_none());
}

#[test]
fn remote_change_close_reopen_and_purge_have_distinct_ops_including_cold_close() {
    for cold in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        if cold {
            SortedSnapshot::write(
                directory.path().join("index.snap"),
                &SummaryIndex::new().apply(1, remote("row", 1)),
            )
            .unwrap();
        }
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        if !cold {
            writer.apply(remote("row", 1)).unwrap();
        }
        let subscription = hub.subscribe(&Sub::new("close", "list")).unwrap();
        let mut closed = remote("row", 2);
        closed.state = "closed".into();
        if cold {
            // The remote tee waits for the initial hot read before draining marks.
            writer.process_batch();
            writer.apply_from(Source::V1, closed.clone()).unwrap();
        } else {
            hub.submit(closed.clone()).unwrap();
            writer.process_batch();
        }
        let item = subscription.receiver.try_next().unwrap();
        assert!(matches!(item, ListItem::Summary(ref event) if event.summary.state == "closed"));
        assert!(subscription.receiver.try_next().is_none());
        assert!(ids(&hub).is_empty());
        let closed_seq = hub.snapshot().seq();
        hub.submit(closed).unwrap();
        writer.process_batch();
        assert_eq!(hub.snapshot().seq(), closed_seq, "a second closed summary must append nothing");
        drop((subscription, hub, writer));
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        assert!(ids(&hub).is_empty(), "cold live row was resurrected by replay");
        let subscription = hub.subscribe(&Sub::new("reopen", "list")).unwrap();
        hub.submit(remote("row", 3)).unwrap();
        writer.process_batch();
        assert!(
            matches!(subscription.receiver.try_next(), Some(ListItem::Summary(event)) if event.summary.state == "running")
        );
        let mut changed = remote("row", 4);
        changed.title = "changed".into();
        hub.submit(changed).unwrap();
        writer.process_batch();
        assert!(
            matches!(subscription.receiver.try_next(), Some(ListItem::Summary(event)) if event.summary.title == "changed")
        );
        hub.remove("peer", "row").unwrap();
        writer.process_batch();
        assert!(
            matches!(subscription.receiver.try_next(), Some(ListItem::Gone { origin, chat_id, .. }) if origin == "peer" && chat_id == "row")
        );
        assert!(subscription.receiver.try_next().is_none());
        assert!(ids(&hub).is_empty());
    }
}

#[test]
fn sixty_thousand_remote_closed_rows_read_no_snapshot_pieces() {
    let directory = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    for peer in 0..30 {
        for n in 0..500 {
            let mut row = remote(format!("live-{n}"), n + 1);
            row.origin = format!("peer-{peer}");
            index = index.apply(index.seq() + 1, row);
        }
    }
    SortedSnapshot::write(directory.path().join("index.snap"), &index).unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    for _ in 0..60 {
        writer.process_batch();
    }
    assert!(writer.hydration.is_none());
    assert_eq!(hub.snapshot().len(), 15_000);
    let seq = hub.snapshot().seq();
    let bytes = writer.log.as_ref().unwrap().offset();
    for peer in 0..30 {
        for n in 0..2_000 {
            let mut row = remote(format!("closed-{n}"), n + 1);
            row.origin = format!("peer-{peer}");
            row.state = "closed".into();
            writer.apply_from(Source::V1, row).unwrap();
        }
    }
    assert_eq!(writer.turn_measure.apply_snapshot_pieces, 0);
    assert_eq!(hub.snapshot().seq(), seq);
    assert_eq!(writer.log.as_ref().unwrap().offset(), bytes);
    assert_eq!(hub.snapshot().len(), 15_000);
    assert!(hub.snapshot().iter().all(|row| row.is_live()));
}

#[tokio::test]
async fn remote_marks_can_wait_for_bounded_startup_hydration() {
    let directory = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    for n in 0..600 {
        index = index.apply(n + 1, remote(format!("row-{n}"), n + 1));
    }
    SortedSnapshot::write(directory.path().join("index.snap"), &index).unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    let subscription = hub.subscribe(&Sub::new("startup-close", "list")).unwrap();
    writer.process_batch();
    assert!(matches!(*hub.hydrated.borrow(), disk::HydrationState::Loading));
    drive(&mut writer, 3);
    tokio::time::timeout(std::time::Duration::from_secs(1), hub.wait_hydrated())
        .await
        .unwrap()
        .unwrap();
    let mut closed = remote("row-0", 1000);
    closed.state = "closed".into();
    hub.submit(closed).unwrap();
    writer.process_batch();
    assert_eq!(writer.turn_measure.apply_snapshot_pieces, 0);
    assert!(
        matches!(subscription.receiver.try_next(), Some(ListItem::Summary(event)) if !event.summary.is_live())
    );
    assert!(hub.snapshot().get_row(&RowKey::new("peer", "row-0")).is_none());
    assert_eq!(hub.snapshot().len(), 599);
}

#[tokio::test]
async fn compaction_finishes_the_startup_hot_read_and_releases_waiters() {
    let directory = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    for n in 0..600 {
        index = index.apply(n + 1, remote(format!("row-{n}"), n + 1));
    }
    SortedSnapshot::write(directory.path().join("index.snap"), &index).unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    writer.next_compaction = Some(std::time::Instant::now());
    writer.process_batch();
    assert!(writer.hydration.is_some());
    assert!(writer.compaction.is_some());
    assert!(matches!(*hub.hydrated.borrow(), disk::HydrationState::Loading));
    writer.finish_compaction(true).await;
    writer.install_compaction();
    assert!(writer.hydration.is_none());
    writer.maintain_compaction();
    assert!(matches!(*hub.hydrated.borrow(), disk::HydrationState::Loading));
    writer.maintain_compaction();
    tokio::time::timeout(std::time::Duration::from_secs(1), hub.wait_hydrated())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(hub.snapshot().iter().filter(|row| row.origin == "peer").count(), 600);
    writer.finish_compaction(true).await;
}

#[tokio::test]
async fn truncated_snapshot_at_hydration_asks_for_a_rebuild() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("index.snap");
    SortedSnapshot::write(&path, &SummaryIndex::new().apply(1, remote("live", 1))).unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    fs::OpenOptions::new().write(true).open(path).unwrap().set_len(0).unwrap();
    writer.process_batch();
    // A short read is structural damage, so hydration ends ready and the
    // writer's next turn rebuilds; only other read errors fail hydration.
    hub.wait_hydrated().await.unwrap();
    assert_eq!(hub.rebuild_count(), 0);
    writer.process_batch();
    assert_eq!(hub.rebuild_count(), 1);
    assert!(hub.snapshot().disk().is_none());
}
