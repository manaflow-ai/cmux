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

fn unit(cursor: u64, ids: &[&str]) -> MirrorUnit {
    MirrorUnit {
        origin: ORIGIN.to_owned(),
        changes: ids
            .iter()
            .map(|id| UnitChange::Summary(Box::new(row(ORIGIN, id, cursor))))
            .collect(),
        mark: MirrorMark { cursor, edition: 4, whole: true },
    }
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
    assert_eq!(titles(&hub), ["a at 1", "b at 2", "c at 2"]);
    assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(2));
    let mut changes = 0;
    while let Some(item) = subscription.receiver.try_next() {
        assert!(matches!(item, ListItem::Summary(_)), "{item:?}");
        changes += 1;
    }
    assert_eq!(changes, 2, "each change of the unit published once");
    assert_eq!(hub.mirror_counts().applied, 3);
}

#[test]
fn a_takeover_writes_the_mark_off_and_a_replay_after_it_gives_no_cursor() {
    let directory = tempfile::tempdir().unwrap();
    {
        let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).unwrap();
        hub.submit_unit(Source::Mirror, unit(5, &["a"])).unwrap();
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
