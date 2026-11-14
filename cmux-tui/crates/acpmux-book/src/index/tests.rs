use super::*;
use std::fs::OpenOptions;
use std::io::Write;
use tempfile::tempdir;

fn summary(id: &str, at: u64, extra: &str) -> Summary {
    let mut summary = Summary::new(id);
    summary.last_activity = at;
    summary.extra = RawValue::from_string(extra.to_owned()).unwrap();
    summary
}

#[test]
fn every_session_state_uses_the_same_live_rule() {
    for state in ["running", "ready", "waiting", "idle", "disconnected"] {
        let mut row = Summary::new(state);
        row.state = state.to_owned();
        assert!(row.is_live(), "{state} should remain in the live view");
    }
    let mut closed = Summary::new("closed");
    closed.state = "closed".to_owned();
    assert!(!closed.is_live());
}

#[test]
fn listed_under_matches_v1_root_and_archive_rules() {
    let mut parent = Summary::new("parent");
    let mut child = Summary::new("child");
    child.parent = Some(parent.key());
    assert!(Summary::listed_under(&child, Some(&parent)));
    assert!(!Summary::listed_under(&child, None));

    let mut nested = Summary::new("nested");
    nested.parent = Some(parent.key());
    parent.parent = Some(RowKey::new("local", "root"));
    assert!(!Summary::listed_under(&nested, Some(&parent)));

    parent.parent = None;
    parent.archived = true;
    assert!(!Summary::listed_under(&child, Some(&parent)));

    parent.archived = true;
    parent.extra =
        RawValue::from_string("{\"tags\":{\"archived\":\"reason\"}}".to_owned()).unwrap();
    assert!(!Summary::listed_under(&child, Some(&parent)));
    assert!(!Summary::listed_under(&parent, Some(&parent)));

    parent.archived = false;
    parent.extra = RawValue::from_string("{\"tags\":{}}".to_owned()).unwrap();
    child.parent = Some(RowKey::new("local", "other"));
    assert!(!Summary::listed_under(&child, Some(&parent)));
}

#[test]
fn archived_is_typed_through_bounds_and_codec_with_legacy_default() {
    let legacy: Summary = serde_json::from_str(
            r#"{"chatId":"legacy","title":"","harness":"","state":"closed","lastActivity":0,"unread":0,"workspace":null,"origin":"local","pinned":false,"extra":{}}"#,
        )
        .unwrap();
    assert!(!legacy.archived);

    let mut archived = Summary::new("archived");
    archived.archived = true;
    archived.extra =
        RawValue::from_string(format!("{{\"blob\":\"{}\"}}", "x".repeat(8_000))).unwrap();
    let index = SummaryIndex::new().apply(1, archived);
    let row = index.get("archived").unwrap();
    assert!(row.archived);
    assert_eq!(row.extra.get(), "{}");
    let mut child = Summary::new("child");
    child.parent = Some(row.key());
    assert!(!Summary::listed_under(&child, Some(&row)));

    let dir = tempdir().unwrap();
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    log.append(row.as_ref().clone()).unwrap();
    log.sync().unwrap();
    let restored = replay_log(log.path(), SummaryIndex::new()).unwrap();
    assert!(restored.get("archived").unwrap().archived);
}

#[test]
fn live_pages_use_the_live_ordered_set() {
    let mut running = summary("running", 3, "{}");
    running.state = "running".to_owned();
    let mut closed = summary("closed", 2, "{}");
    closed.state = "closed".to_owned();
    let mut waiting = summary("waiting", 1, "{}");
    waiting.state = "waiting".to_owned();
    let index = SummaryIndex::new().apply(1, running).apply(2, closed).apply(3, waiting);
    let page = index.read_live_page(None, ReadSide::After, false, 10, 64 * 1024, None).unwrap();
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["running", "waiting"]
    );
    let mut closed_again = Summary::new("closed");
    closed_again.state = "closed".to_owned();
    let closed = index.apply(4, closed_again);
    let page = closed.read_live_page(None, ReadSide::After, false, 10, 64 * 1024, None).unwrap();
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["running", "waiting"]
    );
}

#[test]
fn live_pages_match_an_index_containing_only_live_rows() {
    let mut index = SummaryIndex::new();
    let mut live = SummaryIndex::new();
    for n in 0..30 {
        let mut row = summary(&format!("row-{n:02}"), 30 - n, "{}");
        row.state = if n % 3 == 0 { "closed" } else { "running" }.into();
        row.workspace = Some(format!("workspace-{}", n % 2));
        row.origin = if n % 2 == 0 { "local" } else { "peer" }.into();
        if row.is_live() {
            live = live.apply(n + 1, row.clone());
        }
        index = index.apply(n + 1, row);
    }
    let anchors = std::iter::once(None)
        .chain(index.iter().map(|row| Some(SortKey::of(row))))
        .collect::<Vec<_>>();
    let filters = [
        None,
        Some(ListFilter { workspace: Some("workspace-0".into()), ..Default::default() }),
        Some(ListFilter { origin: Some("peer".into()), ..Default::default() }),
        Some(ListFilter { state: Some("waiting".into()), ..Default::default() }),
    ];
    for anchor in &anchors {
        for side in [ReadSide::Before, ReadSide::After, ReadSide::Around] {
            for inclusive in [false, true] {
                for limit in [1, 2, 7, 30] {
                    for bytes in [600, 8192] {
                        for filter in &filters {
                            let actual = index
                                .read_live_page(
                                    anchor.as_ref(),
                                    side,
                                    inclusive,
                                    limit,
                                    bytes,
                                    filter.as_ref(),
                                )
                                .unwrap();
                            let expected = live
                                .read_page(
                                    anchor.as_ref(),
                                    side,
                                    inclusive,
                                    limit,
                                    bytes,
                                    filter.as_ref(),
                                )
                                .unwrap();
                            assert_eq!(actual.before_key, expected.before_key);
                            assert_eq!(actual.after_key, expected.after_key);
                            assert_eq!(actual.has_before, expected.has_before);
                            assert_eq!(actual.has_after, expected.has_after);
                            assert_eq!(
                                actual.rows.iter().map(|row| row.key()).collect::<Vec<_>>(),
                                expected.rows.iter().map(|row| row.key()).collect::<Vec<_>>(),
                            );
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn a_thousand_state_changes_keep_live_pages_equal_to_the_ordered_filter() {
    let mut index = SummaryIndex::new();
    let mut random = 0x5c_143_u64;
    for seq in 1..=1000 {
        random ^= random << 13;
        random ^= random >> 7;
        random ^= random << 17;
        let mut row = Summary::new(format!("chat-{}", random % 53));
        row.origin = if random & 64 == 0 { "local" } else { "peer" }.into();
        row.state = match (random >> 8) % 5 {
            0 => "closed",
            1 => "running",
            2 => "waiting",
            3 => "idle",
            _ => "ready",
        }
        .into();
        // Ties and movement both exercise ordering across reopen/close.
        row.last_activity = (random >> 16) % 31;
        index = index.apply(seq, row);
        let expected = index
            .iter()
            .filter(|row| row.is_live())
            .map(|row| (SortKey::of(row), row.state.clone()))
            .collect::<Vec<_>>();
        let mut actual = Vec::new();
        let mut anchor = None;
        loop {
            let page = index
                .read_live_page(anchor.as_ref(), ReadSide::After, false, 7, 8192, None)
                .unwrap();
            actual.extend(page.rows.iter().map(|row| (SortKey::of(row), row.state.clone())));
            if !page.has_after {
                break;
            }
            assert_ne!(page.after_key, anchor);
            anchor = page.after_key;
        }
        assert_eq!(actual, expected, "change {seq}");
    }
}

#[test]
fn every_index_mutator_keeps_live_pages_equal_to_the_ordered_filter() {
    fn assert_live_matches_filter(index: &SummaryIndex) {
        let expected = index
            .iter()
            .filter(|row| row.is_live() && !index.is_origin_removed(row.origin.as_str()))
            .map(|row| row.key())
            .collect::<Vec<_>>();
        let mut actual = Vec::new();
        let mut anchor = None;
        loop {
            let page = index
                .read_live_page(anchor.as_ref(), ReadSide::After, false, 16, 64 * 1024, None)
                .unwrap();
            actual.extend(page.rows.iter().map(|row| row.key()));
            if !page.has_after {
                break;
            }
            anchor = page.after_key;
        }
        assert_eq!(actual, expected);
    }

    let mut peer = summary("peer", 20, "{}");
    peer.origin = "peer".into();
    peer.state = "running".into();
    let mut local = summary("local", 10, "{}");
    local.state = "running".into();
    let mut closed = summary("closed", 5, "{}");
    closed.state = "closed".into();
    let mut index = SummaryIndex::new().apply(1, peer.clone()).apply(2, local).apply(3, closed);
    assert_live_matches_filter(&index);

    let mut hydrated = peer.clone();
    hydrated.last_activity = 30;
    index = index.hydrate(Arc::new(hydrated), 100);
    assert_live_matches_filter(&index);

    let key = peer.key();
    let mut evicted = index;
    assert!(evicted.evict_compacted(&key));
    assert_live_matches_filter(&evicted);
    evicted.hydrate_compacted(Arc::new(peer.clone()));
    assert_live_matches_filter(&evicted);

    let mut removed =
        evicted.apply_origin(10, origin_record("peer".into(), 10, OriginState::Removed));
    assert_live_matches_filter(&removed);
    let (next, count) = removed.remove_origin_batch(10, "peer", 256);
    removed = next;
    assert_eq!(count, 1);
    assert_live_matches_filter(&removed);
    removed = removed.finish_origin_removal("peer");
    assert_live_matches_filter(&removed);

    removed = removed.apply_origin(11, origin_record("peer".into(), 11, OriginState::Connected));
    assert_live_matches_filter(&removed);

    let mut returned = peer.clone();
    returned.chat_id = "peer-returned".into();
    returned.last_activity = 40;
    removed = removed.apply(12, returned.clone());
    assert_live_matches_filter(&removed);
    removed = removed.remove_row(13, &returned.key()).unwrap();
    assert_live_matches_filter(&removed);
    removed = removed.remove_row(14, &RowKey::new("local", "local")).unwrap();
    assert_live_matches_filter(&removed);
    let mut ephemeral = peer;
    ephemeral.chat_id = "peer-ephemeral".into();
    ephemeral.last_activity = 50;
    let removed = removed.apply(15, ephemeral.clone());
    assert_live_matches_filter(&removed);
    let removed = removed.remove_ephemeral(&ephemeral.key());
    assert_live_matches_filter(&removed);

    let dir = tempdir().unwrap();
    let path = dir.path().join("index.snap");
    SortedSnapshot::write(&path, &removed).unwrap();
    let disk = DiskSnapshot::open(&path).unwrap().unwrap();
    let (compacted, _) = removed.with_compacted_snapshot(disk, Default::default());
    assert_live_matches_filter(&compacted);
}

#[test]
fn composite_identity_and_typed_edges_survive_log_snapshot_and_restart() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut local = summary("same", 3, "{\"future\": true}");
    local.parent = Some(RowKey::new("local", "parent"));
    local.fork_of = Some(ForkOf { key: RowKey::new("peer", "fork"), seq: 91 });
    local.folder = Some("/work/project".to_owned());
    let mut peer = local.clone();
    peer.origin = "peer".to_owned();
    let mut log = IndexLog::open(&path).unwrap();
    log.append(local).unwrap();
    log.append(peer).unwrap();
    log.sync().unwrap();
    let index = replay_log(&path, SummaryIndex::new()).unwrap();
    assert_eq!(index.len(), 2);
    log.compact(dir.path().join("index.snap"), &index).unwrap();
    drop(log);
    let mut log = IndexLog::open(&path).unwrap();
    let restored = SortedSnapshot::read(dir.path().join("index.snap")).unwrap().unwrap();
    for origin in ["local", "peer"] {
        let row = restored.get_row(&RowKey::new(origin, "same")).unwrap();
        assert_eq!(row.parent, Some(RowKey::new("local", "parent")));
        assert_eq!(row.fork_of.as_ref().unwrap().seq, 91);
        assert_eq!(row.folder.as_deref(), Some("/work/project"));
    }
    log.append_gone(&RowKey::new("peer", "same")).unwrap();
    log.sync().unwrap();
    let restored = replay_log(log.path(), restored).unwrap();
    assert_eq!(restored.len(), 1);
    assert!(restored.get("same").is_some());
}

#[test]
fn identities_are_never_cut_and_invalid_records_never_append() {
    let dir = tempdir().unwrap();
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    let id = "x".repeat(257);
    let bounded = Summary::new(id.clone()).bounded();
    assert_eq!(bounded.chat_id, id);
    assert!(log.append(bounded).is_err());
    assert_eq!(log.next_seq(), 0);
    assert_eq!(log.offset(), 0);
    let mut escaped = Summary::new("\u{0001}".repeat(256));
    escaped.origin = "\u{0002}".repeat(256);
    assert!(log.append(escaped).is_ok());
}

#[test]
fn applies_one_summary_and_keeps_opaque_extra_bytes() {
    let index = SummaryIndex::new().apply(1, summary("a", 2, "{\"future\": [1, 2]}"));
    assert_eq!(index.len(), 1);
    assert_eq!(index.get("a").unwrap().extra.get(), "{\"future\": [1, 2]}");
    let index = index.apply(2, summary("a", 3, "{\"new\":true}"));
    assert_eq!(index.len(), 1);
    assert_eq!(index.page(0, 2).first().map(|s| s.last_activity), Some(3));
}

#[test]
fn summaries_are_bounded_without_parsing_extra() {
    let mut value = summary("a", 1, "{}");
    value.title = "é".repeat(MAX_TITLE_BYTES);
    value.extra = RawValue::from_string(format!("{{\"text\":\"{}\"}}", "x".repeat(8_000))).unwrap();
    let stored = SummaryIndex::new().apply(1, value).get("a").unwrap();
    assert!(stored.title.len() <= MAX_TITLE_BYTES);
    assert!(stored.encoded_len() <= MAX_SUMMARY_BYTES);
    assert!(stored.title.is_char_boundary(stored.title.len()));
}

fn origin_record(id: String, seq: u64, state: OriginState) -> OriginRecord {
    OriginRecord { seq, id, state, since: seq + 10, extra: None }
}

#[test]
fn snapshot_origin_section_round_trips_and_rejects_bad_records() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("index.snap");
    let mut index = SummaryIndex::new();
    index = index.apply_origin(1, origin_record("peer".into(), 1, OriginState::Connected));
    SortedSnapshot::write(&path, &index).unwrap();
    let disk = DiskSnapshot::open(&path).unwrap().unwrap();
    assert_eq!(disk.origins().next().unwrap().since, 11);
    let rows = std::iter::empty::<io::Result<Arc<Summary>>>();
    let too_many =
        (0..257).map(|n| origin_record(format!("p{n}"), 1, OriginState::Connected)).collect();
    assert!(SortedSnapshot::write_stream_generation(&path, 1, 0, None, 0, too_many, rows).is_err());
    let duplicate = vec![
        origin_record("p".into(), 1, OriginState::Connected),
        origin_record("p".into(), 1, OriginState::Down),
    ];
    let rows = std::iter::empty::<io::Result<Arc<Summary>>>();
    assert!(
        SortedSnapshot::write_stream_generation(&path, 1, 0, None, 0, duplicate, rows).is_err()
    );
}

#[test]
fn removal_visits_only_its_prefix_batch_at_both_index_sizes() {
    for unrelated in [20, 11_000] {
        let mut index = SummaryIndex::new();
        for n in 0..unrelated {
            let row = summary(&format!("other-{n}"), n + 1, "{}");
            index = index.apply(index.seq() + 1, row);
        }
        for n in 0..500 {
            let mut row = summary(&format!("peer-{n}"), n + 1, "{}");
            row.origin = "peer".into();
            index = index.apply(index.seq() + 1, row);
        }
        let mut visited = 0;
        let (_, removed) =
            index.remove_origin_batch_visiting(index.seq(), "peer", 256, || visited += 1);
        assert_eq!(removed, 256);
        assert_eq!(visited, 257);
    }
}

#[test]
fn removed_origin_hidden_candidates_progress_forward_and_backward() {
    let mut index = SummaryIndex::new();
    for n in 0..600 {
        let mut row = summary(&format!("gone-{n}"), 2_000 - n, "{}");
        row.origin = "peer".into();
        row.state = "running".into();
        index = index.apply(n + 1, row);
    }
    for n in 0..50 {
        let mut row = summary(&format!("keep-{n}"), 1_000 - n, "{}");
        row.origin = "other".into();
        row.state = "running".into();
        index = index.apply(700 + n, row);
    }
    index = index.apply_origin(800, origin_record("peer".into(), 800, OriginState::Removed));
    let mut anchor = None;
    let mut seen = Vec::new();
    let mut last = None;
    for turn in 0..20 {
        let page = index
            .read_page(anchor.as_ref(), ReadSide::After, false, 50, snapshot::PAGE_BYTES, None)
            .unwrap();
        assert!(page.rows.iter().all(|row| row.origin == "other"));
        seen.extend(page.rows.iter().map(|row| row.chat_id.clone()));
        if turn < 12 {
            assert!(page.rows.is_empty());
            assert!(page.has_after);
        }
        last = page.after_key.clone();
        if !page.has_after {
            break;
        }
        assert_ne!(anchor, page.after_key);
        anchor = page.after_key;
    }
    assert_eq!(seen.len(), 50);
    assert_eq!(index.len(), 650, "pagination does not wait for cleanup");
    anchor = last;
    let mut backwards = Vec::new();
    for turn in 0..20 {
        let page = index
            .read_page(anchor.as_ref(), ReadSide::Before, turn == 0, 50, snapshot::PAGE_BYTES, None)
            .unwrap();
        assert!(page.rows.iter().all(|row| row.origin == "other"));
        backwards.extend(page.rows.iter().map(|row| row.chat_id.clone()));
        if !page.has_before {
            break;
        }
        assert_ne!(anchor, page.before_key);
        anchor = page.before_key;
    }
    seen.sort();
    backwards.sort();
    assert_eq!(seen, backwards);
}

#[test]
fn live_pages_drop_removed_origin_rows_before_the_origin_returns() {
    fn live_keys(index: &SummaryIndex) -> Vec<RowKey> {
        index
            .read_live_page(None, ReadSide::After, false, 100, snapshot::PAGE_BYTES, None)
            .unwrap()
            .rows
            .iter()
            .map(|row| row.key())
            .collect()
    }

    fn filtered_keys(index: &SummaryIndex) -> Vec<RowKey> {
        index.iter().filter(|row| row.is_live()).map(|row| row.key()).collect()
    }

    let mut index = SummaryIndex::new();
    for (seq, (origin, id, activity)) in
        [("peer", "peer-live-a", 30), ("peer", "peer-live-b", 20), ("local", "local-live", 10)]
            .into_iter()
            .enumerate()
    {
        let mut row = summary(id, activity, "{}");
        row.origin = origin.to_owned();
        index = index.apply(seq as u64 + 1, row);
    }
    assert_eq!(live_keys(&index), filtered_keys(&index));

    index = index.apply_origin(10, origin_record("peer".into(), 10, OriginState::Removed));
    loop {
        let (next, removed) = index.remove_origin_batch(10, "peer", 256);
        index = next;
        if removed == 0 {
            break;
        }
    }
    assert_eq!(live_keys(&index), filtered_keys(&index));
    assert!(!live_keys(&index).iter().any(|key| key.origin.as_ref() == "peer"));

    index = index.apply_origin(11, origin_record("peer".into(), 11, OriginState::Connected));
    let mut returned = summary("peer-live-returned", 40, "{}");
    returned.origin = "peer".to_owned();
    index = index.apply(12, returned);
    assert_eq!(live_keys(&index), filtered_keys(&index));
    assert_eq!(live_keys(&index).iter().filter(|key| key.origin.as_ref() == "peer").count(), 1);
}

#[test]
fn log_and_sorted_snapshot_replay() {
    let dir = tempdir().unwrap();
    let log_path = dir.path().join("index.log");
    let snap_path = dir.path().join("index.snap");
    let mut log = IndexLog::open(&log_path).unwrap();
    let first = log.append(summary("a", 2, "{\"x\":1}")).unwrap();
    let second = log.append(summary("b", 1, "null")).unwrap();
    log.sync().unwrap();
    let index =
        SummaryIndex::new().apply(first.seq, first.summary).apply(second.seq, second.summary);
    SortedSnapshot::write(&snap_path, &index).unwrap();
    let restored = SortedSnapshot::read(&snap_path).unwrap().unwrap();
    assert_eq!(restored.seq(), 2);
    assert_eq!(
        restored.page(0, 2).iter().map(|s| s.chat_id.as_str()).collect::<Vec<_>>(),
        ["a", "b"]
    );
    assert_eq!(replay_log(&log_path, SummaryIndex::new()).unwrap().len(), 2);
}

#[test]
fn open_truncates_a_torn_tail_before_the_next_append() {
    let dir = tempdir().unwrap();
    let log_path = dir.path().join("index.log");
    let mut log = IndexLog::open(&log_path).unwrap();
    log.append(summary("a", 1, "{}")).unwrap();
    log.sync().unwrap();
    OpenOptions::new()
        .append(true)
        .open(&log_path)
        .unwrap()
        .write_all(br#"{"seq":99,"chatId":"torn""#)
        .unwrap();
    drop(log);
    let mut reopened = IndexLog::open(&log_path).unwrap();
    let record = reopened.append(summary("b", 2, "{}")).unwrap();
    assert_eq!(record.seq, 2);
    reopened.sync().unwrap();
    assert_eq!(replay_log(&log_path, SummaryIndex::new()).unwrap().len(), 2);
}

#[test]
fn snapshot_carries_the_log_offset_and_compaction_starts_a_new_tail() {
    let dir = tempdir().unwrap();
    let log_path = dir.path().join("index.log");
    let snap_path = dir.path().join("index.snap");
    let mut log = IndexLog::open(&log_path).unwrap();
    let record = log.append(summary("a", 1, "{}")).unwrap();
    log.sync().unwrap();
    let index = SummaryIndex::new().apply(record.seq, record.summary);
    log.compact(&snap_path, &index).unwrap();
    let (restored, offset) = SortedSnapshot::read_with_offset(&snap_path).unwrap().unwrap();
    assert_eq!(offset, 0);
    assert_eq!(replay_log_from(&log_path, offset, restored).unwrap().len(), 1);
    drop(log);
    let mut reopened = IndexLog::open(&log_path).unwrap();
    let next = reopened.append(summary("b", 2, "{}")).unwrap();
    assert_eq!(next.seq, 2);
    reopened.sync().unwrap();
    let restored = SortedSnapshot::read(&snap_path).unwrap().unwrap();
    assert_eq!(replay_log_from(reopened.path(), 0, restored).unwrap().seq(), 2);
}

#[test]
fn folder_projection_matches_rebuild_after_ten_thousand_hot_updates() {
    use std::collections::BTreeMap;

    let mut index = SummaryIndex::new();
    let mut seed = 0x5f_u64;
    for seq in 1..=10_000 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        let id = format!("chat-{}", (seed >> 32) % 64);
        let mut row = Summary::new(id);
        row.origin = if seed & 1 == 0 { "local" } else { "peer" }.into();
        row.state = if seed & 7 == 0 { "closed" } else { "running" }.into();
        row.last_activity = seed;
        row.folder = (seed & 3 != 0).then(|| format!("/folder-{}", (seed >> 8) % 17));
        index = index.apply_summary(seq, row);

        let mut model = BTreeMap::<folders::FolderKey, (SortKey, RowKey, u32)>::new();
        for hot in index.iter() {
            let Some(folder) = FolderKey::of(hot) else { continue };
            let key = folders::FolderKey::new(folder.origin.clone(), folder.folder.clone());
            let sort = SortKey::of(hot);
            let entry = model.entry(key).or_insert_with(|| (sort.clone(), hot.key(), 0));
            if sort < entry.0 {
                entry.0 = sort.clone();
                entry.1 = hot.key();
            }
            entry.2 += 1;
        }
        let rebuilt = model
            .into_iter()
            .try_fold(folders::Folders::new(), |view, (key, (sort, newest, count))| {
                view.apply(folders::FolderEntry::new(
                    key.origin,
                    key.folder,
                    Some(newest),
                    sort.last_activity,
                    count,
                ))
                .map(|(view, _)| view)
            })
            .unwrap();
        let actual =
            index.folders().iter().map(|row| (row.key(), row.as_ref().clone())).collect::<Vec<_>>();
        let expected =
            rebuilt.iter().map(|row| (row.key(), row.as_ref().clone())).collect::<Vec<_>>();
        assert_eq!(actual, expected, "folder projection mismatch at update {seq}");
    }
}
