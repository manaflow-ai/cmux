//! The mirror's unit through the hub queue and the writer.
use super::*;

const ORIGIN: &str = "peer-a";

fn row(origin: &str, id: &str, activity: u64) -> Summary {
    let mut summary = Summary::new(id);
    summary.origin = origin.to_owned();
    summary.state = "running".to_owned();
    summary.title = format!("{id} at {activity}");
    summary.last_activity = activity;
    summary
}

fn mark(cursor: u64) -> MirrorMark {
    MirrorMark { cursor, edition: 4, whole: true }
}

/// The unit at `cursor`, following the mark at `cursor - 1` (none at 1).
fn unit(cursor: u64, ids: &[&str]) -> MirrorUnit {
    MirrorUnit {
        origin: ORIGIN.to_owned(),
        after: (cursor > 1).then(|| mark(cursor - 1)),
        changes: ids
            .iter()
            .map(|id| UnitChange::Summary(Box::new(row(ORIGIN, id, cursor))))
            .collect(),
        mark: mark(cursor),
    }
}

/// A walk's first unit: it follows no mark.
fn first(cursor: u64, ids: &[&str]) -> MirrorUnit {
    MirrorUnit { after: None, ..unit(cursor, ids) }
}

fn titles(hub: &Hub) -> Vec<String> {
    let mut titles: Vec<_> = hub
        .snapshot()
        .iter()
        .filter(|row| row.origin == ORIGIN)
        .map(|row| row.title.clone())
        .collect();
    titles.sort();
    titles
}

#[test]
fn a_unit_refused_by_a_full_queue_leaves_nothing_and_applies_once_when_given_again() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    hub.submit_unit(Source::Mirror, unit(1, &["a", "b"])).unwrap();
    let refused = hub.submit_unit(Source::Mirror, unit(2, &["b", "c"]));
    assert!(matches!(refused, Err(HubError::UnitQueueFull)), "{refused:?}");
    assert_eq!(hub.mirror_counts().full, 1);
    assert!(titles(&hub).is_empty());
    assert_eq!(hub.mirror_mark(ORIGIN), None);
    writer.process_batch();
    assert_eq!(titles(&hub), ["a at 1", "b at 1"]);
    assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(1));
    let subscription = hub.subscribe(&Sub::new("unit", "list")).unwrap();
    hub.submit_unit(Source::Mirror, unit(2, &["b", "c"])).unwrap();
    writer.process_batch();
    let seq = hub.snapshot().seq();
    hub.submit_unit(Source::Mirror, unit(2, &["b", "c"])).unwrap();
    writer.process_batch();
    assert_eq!(hub.snapshot().seq(), seq, "the second copy wrote no row");
    assert_eq!(hub.mirror_counts().out_of_order, 1, "it follows a mark that moved on");
    assert_eq!(titles(&hub), ["a at 1", "b at 2", "c at 2"]);
    assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(2));
    let mut changes = 0;
    while let Some(item) = subscription.receiver.try_next() {
        assert!(matches!(item, ListItem::Summary(_)), "{item:?}");
        changes += 1;
    }
    assert_eq!(changes, 2, "each change of the unit published once");
    assert_eq!(hub.mirror_counts().applied, 2);
}

#[test]
fn a_takeover_writes_the_mark_off_and_a_replay_after_it_gives_no_cursor() {
    let directory = tempfile::tempdir().unwrap();
    {
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        hub.submit_unit(Source::Mirror, first(5, &["a"])).unwrap();
        writer.process_batch();
        writer.sync_batch().unwrap();
        assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(5));
    }
    {
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(5), "a restart resumes");
        // Even the owner's own takeover walks: the mark goes off in its turn.
        hub.takeover(ORIGIN, Source::Mirror).unwrap();
        writer.process_batch();
        writer.sync_batch().unwrap();
        assert_eq!(hub.mirror_mark(ORIGIN), None);
        assert_eq!(titles(&hub), ["a at 5"], "a takeover never clears");
    }
    let (hub, _writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    assert_eq!(hub.mirror_mark(ORIGIN), None);
    assert_eq!(titles(&hub), ["a at 5"]);
}

#[test]
fn a_unit_naming_another_origin_is_refused_whole_and_counted() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let mut forged = unit(1, &["a"]);
    forged.changes.push(UnitChange::Summary(Box::new(row("peer-b", "x", 1))));
    let result = hub.submit_unit(Source::Mirror, forged);
    assert!(matches!(result, Err(HubError::ForgedOrigin(_))), "{result:?}");
    let local = MirrorUnit { origin: "local".to_owned(), ..unit(1, &[]) };
    assert!(hub.submit_unit(Source::Mirror, local).is_err());
    writer.process_batch();
    assert_eq!(hub.mirror_counts().forged, 2);
    assert!(hub.snapshot().is_empty());
    assert_eq!(hub.mirror_mark(ORIGIN), None);
}

#[test]
fn a_unit_from_a_source_that_does_not_own_the_origin_is_refused_whole_and_counted() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    hub.submit_from(Source::V1, row(ORIGIN, "v1-row", 1)).unwrap();
    writer.process_batch();
    hub.submit_unit(Source::Mirror, unit(3, &["a", "b"])).unwrap();
    writer.process_batch();
    assert_eq!(hub.mirror_counts().not_owner, 1);
    assert_eq!(titles(&hub), ["v1-row at 1"]);
    assert_eq!(hub.mirror_mark(ORIGIN), None);
    // The refusal freed the origin's slot: the next unit is not full.
    hub.submit_unit(Source::Mirror, unit(4, &["a"])).unwrap();
}

#[test]
fn a_unit_over_the_bound_is_refused_and_its_rows_counted() {
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    let ids: Vec<String> = (0..=MAX_UNIT_CHANGES).map(|n| format!("r{n}")).collect();
    let refs: Vec<&str> = ids.iter().map(String::as_str).collect();
    let result = hub.submit_unit(Source::Mirror, unit(1, &refs));
    assert!(matches!(result, Err(HubError::UnitRowLimit)), "{result:?}");
    assert_eq!(hub.mirror_counts().rows_over_bound, MAX_UNIT_CHANGES as u64 + 1);
}

#[test]
fn units_and_takeovers_leave_the_origin_slot_in_their_order() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    hub.takeover(ORIGIN, Source::Mirror).unwrap();
    hub.submit_unit(Source::Mirror, unit(1, &["a"])).unwrap();
    hub.takeover(ORIGIN, Source::V1).unwrap();
    for _ in 0..3 {
        writer.process_batch();
    }
    assert_eq!(titles(&hub), ["a at 1"], "the unit went in under the takeover before it");
    assert_eq!(hub.mirror_mark(ORIGIN), None, "the takeover after it wrote the mark off");
    assert_eq!(hub.source(ORIGIN), Some(Source::V1));
    hub.submit_unit(Source::Mirror, unit(2, &["b"])).unwrap();
    writer.process_batch();
    assert_eq!(hub.mirror_counts().not_owner, 1);
    assert_eq!(titles(&hub), ["a at 1"]);
}

#[test]
fn removals_and_closed_rows_follow_the_remote_row_rules() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    hub.submit_unit(Source::Mirror, unit(1, &["a", "b"])).unwrap();
    writer.process_batch();
    let mut closed = row(ORIGIN, "a", 2);
    closed.state = "closed".to_owned();
    let mut never = row(ORIGIN, "never-live", 2);
    never.state = "closed".to_owned();
    hub.submit_unit(
        Source::Mirror,
        MirrorUnit {
            origin: ORIGIN.to_owned(),
            after: Some(mark(1)),
            changes: vec![
                UnitChange::Summary(Box::new(closed)),
                UnitChange::Summary(Box::new(never)),
                UnitChange::Gone { chat_id: "b".to_owned() },
                UnitChange::Gone { chat_id: "absent".to_owned() },
            ],
            mark: MirrorMark { cursor: 2, edition: 4, whole: true },
        },
    )
    .unwrap();
    writer.process_batch();
    let index = hub.snapshot();
    assert!(index.get_row(&RowKey::new(ORIGIN, "b")).is_none());
    assert!(index.get_row(&RowKey::new(ORIGIN, "never-live")).is_none());
    assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(2));
}

fn log_path(writer: &HubWriter) -> PathBuf {
    writer.log.as_ref().expect("disk log").path().to_owned()
}

/// A frame that only moves the cursor, or turns `whole` true after a walk's
/// last page, is written: its mark alone, carrying the sequence of a record
/// that is not its own row. The opener keeps it, and a takeover's write-off
/// after it, without cutting the log.
#[test]
fn a_unit_with_no_rows_writes_its_mark_alone_and_reopens_whole() {
    let directory = tempfile::tempdir().unwrap();
    let path;
    {
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        hub.submit_unit(Source::Mirror, unit(1, &["a"])).unwrap();
        writer.process_batch();
        hub.submit(row("local", "mine", 3)).unwrap();
        writer.process_batch();
        let seq = hub.snapshot().seq();
        let walked = MirrorUnit {
            origin: ORIGIN.to_owned(),
            after: Some(mark(1)),
            changes: Vec::new(),
            mark: MirrorMark { cursor: 2, edition: 4, whole: true },
        };
        hub.submit_unit(Source::Mirror, walked).unwrap();
        writer.process_batch();
        writer.sync_batch().unwrap();
        assert_eq!(hub.snapshot().seq(), seq, "a mark takes no sequence");
        assert_eq!(
            hub.mirror_mark(ORIGIN),
            Some(MirrorMark { cursor: 2, edition: 4, whole: true })
        );
        path = log_path(&writer);
    }
    let length = fs::metadata(&path).unwrap().len();
    {
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().len(), length, "the opener cut nothing");
        assert_eq!(
            hub.mirror_mark(ORIGIN),
            Some(MirrorMark { cursor: 2, edition: 4, whole: true })
        );
        hub.takeover(ORIGIN, Source::Mirror).unwrap();
        writer.process_batch();
        writer.sync_batch().unwrap();
    }
    let length = fs::metadata(&path).unwrap().len();
    let (hub, _writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    assert_eq!(fs::metadata(&path).unwrap().len(), length, "the write-off was kept");
    assert_eq!(hub.mirror_mark(ORIGIN), None);
    assert!(hub.snapshot().get_row(&RowKey::new("local", "mine")).is_some());
}

/// At most two units per origin are unapplied: one in the writer's storage
/// retry and one more the slot took while that append failed. A third is
/// refused with nothing applied. The two are written as one append, rows of
/// both and then the newer mark, so no cut leaves the newer mark over the
/// older unit's rows alone.
#[test]
fn the_bound_is_two_frames_joined_into_one_append() {
    let directory = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    hub.submit_unit(Source::Mirror, unit(1, &["a", "b"])).unwrap();
    let batch = hub.updates.take_batch();
    // The slot is free while the writer holds the first unit.
    hub.submit_unit(Source::Mirror, unit(2, &["c"])).unwrap();
    writer.mirror.fail_appends = 1;
    for (key, update) in batch {
        assert!(writer.dispatch_update(key, update).is_err(), "the append failed");
    }
    assert_eq!(hub.mirror_counts().storage, 1);
    let refused = hub.submit_unit(Source::Mirror, unit(3, &["d"]));
    assert!(matches!(refused, Err(HubError::UnitQueueFull)), "{refused:?}");
    assert_eq!(hub.mirror_counts().full, 1);
    assert!(titles(&hub).is_empty());
    assert_eq!(hub.mirror_mark(ORIGIN), None);
    let start = writer.log.as_ref().unwrap().offset();
    writer.process_batch();
    writer.sync_batch().unwrap();
    assert_eq!(titles(&hub), ["a at 1", "b at 1", "c at 2"]);
    assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(2));
    assert_eq!(hub.mirror_counts().applied, 1, "one append for both");
    // The slot is free again.
    hub.submit_unit(Source::Mirror, unit(3, &["d"])).unwrap();
    let path = log_path(&writer);
    let end = writer.log.as_ref().unwrap().offset();
    drop((hub, writer));
    let bytes = fs::read(&path).unwrap();
    for cut in start..=end {
        let copy = tempfile::tempdir().unwrap();
        fs::write(copy.path().join("index.log"), &bytes[..cut as usize]).unwrap();
        let (hub, _writer) = Hub::open(copy.path(), 101, || 7).unwrap();
        if hub.mirror_mark(ORIGIN).is_some() {
            assert_eq!(cut, end, "the mark is the append's last bytes");
            assert_eq!(titles(&hub), ["a at 1", "b at 1", "c at 2"]);
        }
    }
}

/// A kill between a unit's last row and its mark: the rows are on disk, the
/// mark is the older one, and the resumed frame brings the same rows again.
/// The writer drops the equal rows, so a subscriber gets nothing the first
/// apply did not already send.
#[test]
fn a_kill_before_the_mark_resumes_with_no_second_op() {
    let directory = tempfile::tempdir().unwrap();
    let path;
    {
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        hub.submit_unit(Source::Mirror, unit(1, &["a"])).unwrap();
        writer.process_batch();
        hub.submit_unit(Source::Mirror, unit(2, &["a", "b"])).unwrap();
        writer.process_batch();
        writer.sync_batch().unwrap();
        path = log_path(&writer);
    }
    let mark = acpmux_book::index::MarkRecord {
        seq: 0,
        origin: ORIGIN.to_owned(),
        mark: Some(MirrorMark { cursor: 2, edition: 4, whole: true }),
    };
    let length = fs::metadata(&path).unwrap().len();
    let file = fs::OpenOptions::new().write(true).open(&path).unwrap();
    file.set_len(length - mark.encoded_len()).unwrap();
    drop(file);
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(1), "the older mark");
    assert_eq!(titles(&hub), ["a at 2", "b at 2"], "the rows are on disk");
    let seq = hub.snapshot().seq();
    let subscription = hub.subscribe(&Sub::new("resume", "list")).unwrap();
    hub.submit_unit(Source::Mirror, unit(2, &["a", "b"])).unwrap();
    writer.process_batch();
    assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(2));
    assert_eq!(hub.snapshot().seq(), seq, "no row written again");
    assert!(subscription.receiver.try_next().is_none(), "no second op");
}

/// A row of another producer waiting in a keyed slot for a mirrored origin
/// is refused by ownership and counted in `refused_source_submits`.
#[test]
fn a_keyed_row_refused_by_ownership_is_counted() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    hub.submit_unit(Source::Mirror, unit(1, &["a"])).unwrap();
    writer.process_batch();
    let before = refused_source_submits();
    hub.submit_from(Source::V1, row(ORIGIN, "a", 9)).unwrap();
    writer.process_batch();
    assert!(refused_source_submits() > before);
    assert_eq!(titles(&hub), ["a at 1"]);
}

/// Applies one queued batch without the turn's storage retry, so a failed
/// append stays in the retry.
fn dispatch_batch(hub: &Hub, writer: &mut HubWriter) -> Vec<Result<(), HubError>> {
    hub.updates
        .take_batch()
        .into_iter()
        .map(|(key, update)| writer.dispatch_update(key, update))
        .collect()
}

/// `submit_unit` accepted the unit, then the writer dropped it as held (an
/// origin record waiting in the storage retry). The stream's next unit
/// follows the dropped unit's mark, which never landed: refused whole. The
/// dialer starts again from the mark on disk.
#[test]
fn a_unit_dropped_as_held_refuses_the_next_one() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    hub.submit_unit(Source::Mirror, unit(1, &["a"])).unwrap();
    writer.process_batch();
    let record = writer.published.load().origin(ORIGIN).cloned().unwrap_or(OriginRecord {
        seq: 0,
        id: ORIGIN.into(),
        state: OriginState::Connected,
        since: 0,
        extra: None,
    });
    writer.origins.retry.insert(ORIGIN.to_owned(), record);
    hub.submit_unit(Source::Mirror, unit(2, &["b"])).unwrap();
    assert!(matches!(dispatch_batch(&hub, &mut writer)[..], [Err(HubError::UnitHeld)]));
    writer.origins.retry.remove(ORIGIN);
    hub.submit_unit(Source::Mirror, unit(3, &["c"])).unwrap();
    assert!(matches!(dispatch_batch(&hub, &mut writer)[..], [Err(HubError::UnitOutOfOrder)]));
    let counts = hub.mirror_counts();
    assert_eq!((counts.held, counts.out_of_order), (1, 1));
    assert_eq!(titles(&hub), ["a at 1"], "no row of either unit");
    assert_eq!(hub.mirror_mark(ORIGIN), Some(mark(1)), "the mark did not move");
    // The resume from the mark brings both frames again.
    hub.submit_unit(Source::Mirror, unit(2, &["b", "c"])).unwrap();
    writer.process_batch();
    assert_eq!(titles(&hub), ["a at 1", "b at 2", "c at 2"]);
    assert_eq!(hub.mirror_mark(ORIGIN), Some(mark(2)));
}

/// A removal drops the origin's mark. A unit that follows the mark from
/// before it is refused whole; a walk's first unit applies.
#[test]
fn a_removal_between_two_units_refuses_the_second() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    hub.submit_unit(Source::Mirror, unit(1, &["a"])).unwrap();
    writer.process_batch();
    writer.origin(ORIGIN, OriginState::Removed, 2).unwrap();
    for _ in 0..4 {
        writer.process_batch();
    }
    writer.origin(ORIGIN, OriginState::Connected, 3).unwrap();
    assert_eq!(hub.mirror_mark(ORIGIN), None);
    hub.submit_unit(Source::Mirror, unit(2, &["b"])).unwrap();
    writer.process_batch();
    assert_eq!(hub.mirror_counts().out_of_order, 1);
    assert!(titles(&hub).is_empty(), "no row of the refused unit");
    hub.submit_unit(Source::Mirror, first(7, &["c"])).unwrap();
    writer.process_batch();
    assert_eq!(titles(&hub), ["c at 7"]);
    assert_eq!(hub.mirror_mark(ORIGIN), Some(mark(7)));
}

/// A takeover between two units writes the mark off, so the second is
/// refused; a unit still in the storage retry is dropped by the takeover.
#[test]
fn a_takeover_between_two_units_refuses_the_second() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    hub.submit_unit(Source::Mirror, unit(1, &["a"])).unwrap();
    writer.process_batch();
    hub.takeover(ORIGIN, Source::Mirror).unwrap();
    writer.process_batch();
    hub.submit_unit(Source::Mirror, unit(2, &["b"])).unwrap();
    writer.process_batch();
    assert_eq!(hub.mirror_counts().out_of_order, 1);
    assert_eq!(titles(&hub), ["a at 1"]);
    assert_eq!(hub.mirror_mark(ORIGIN), None);
    assert_eq!(writer.log_errors(), 0, "a refusal is not a storage error");

    let directory = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    hub.submit_unit(Source::Mirror, unit(1, &["a"])).unwrap();
    writer.mirror.fail_appends = 1;
    assert!(dispatch_batch(&hub, &mut writer)[0].is_err(), "the append failed");
    hub.takeover(ORIGIN, Source::Mirror).unwrap();
    dispatch_batch(&hub, &mut writer);
    assert!(!writer.mirror.retry_pending(), "the takeover dropped the retry unit");
    assert_eq!(hub.mirror_counts().out_of_order, 1);
    writer.process_batch();
    writer.sync_batch().unwrap();
    assert!(titles(&hub).is_empty(), "the dropped unit wrote nothing");
    hub.submit_unit(Source::Mirror, first(4, &["b"])).unwrap();
    writer.process_batch();
    assert_eq!(titles(&hub), ["b at 4"]);
    assert_eq!(hub.mirror_mark(ORIGIN), Some(mark(4)));
}

/// A unit in the storage retry joins the next unit only when that unit
/// follows its mark from the same source. A walk's first unit after it is
/// not a continuation: the earlier unit is dropped and counted, and only the
/// new one is written.
#[test]
fn a_join_is_refused_when_the_next_unit_does_not_follow() {
    let directory = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
    hub.submit_unit(Source::Mirror, unit(1, &["a"])).unwrap();
    let batch = hub.updates.take_batch();
    // The slot takes the walk's first unit while the writer holds unit 1.
    hub.submit_unit(Source::Mirror, first(9, &["b"])).unwrap();
    writer.mirror.fail_appends = 1;
    for (key, update) in batch {
        assert!(writer.dispatch_update(key, update).is_err(), "the append failed");
    }
    writer.process_batch();
    let counts = hub.mirror_counts();
    assert_eq!((counts.join_refused, counts.applied), (1, 1));
    assert_eq!(titles(&hub), ["b at 9"], "the dropped unit's row was not written");
    assert_eq!(hub.mirror_mark(ORIGIN), Some(mark(9)));
    assert!(!writer.mirror.retry_pending());
}
