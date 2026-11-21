//! Reader contracts for the snapshot-backed cold family part (v2 row 5i).
//! These tests deliberately use the public page operation so the table and the
//! pager have the same visibility, cursor and byte-budget rules.
use super::*;
use tempfile::TempDir;

fn closed(id: impl Into<String>, activity: u64) -> Summary {
    let mut row = Summary::new(id.into());
    row.last_activity = activity;
    row.state = "closed".to_owned();
    row
}

fn child(mut row: Summary, parent: &Summary) -> Summary {
    row.parent = Some(parent.key());
    row
}

fn snapshot_fixture(with_table: bool) -> (TempDir, SummaryIndex, RowKey, Vec<String>) {
    let dir = tempfile::tempdir().unwrap();
    let snapshot = dir.path().join("index.snap");
    let table = dir.path().join("index.snap.kin");
    let root = closed("family-root", 1);
    let root_key = root.key();
    let mut rows = vec![root.clone()];
    let cold_parent = child(closed("cold-parent", 2), &root);
    rows.push(cold_parent.clone());
    let mut expected = vec![cold_parent.chat_id.clone()];
    for n in 0..2 {
        let row = child(closed(format!("cold-grand-{n}"), 3), &cold_parent);
        expected.push(row.chat_id.clone());
        rows.push(row);
    }
    for n in 0..5 {
        let row = child(closed(format!("cold-direct-{n}"), 3), &root);
        expected.push(row.chat_id.clone());
        rows.push(row);
    }
    rows.push(child(closed("unrelated", 4), &closed("other-root", 1)));
    let mut index = SummaryIndex::new();
    for (seq, row) in rows.iter().cloned().enumerate() {
        index = index.apply(seq as u64 + 1, row);
    }
    let stream = index.merged_rows();
    if with_table {
        SortedSnapshot::write_stream_generation_with_table(StreamGeneration {
            path: &snapshot,
            seq: index.seq(),
            log_offset: 0,
            log_name: None,
            covered_generation: 0,
            meta: SnapshotMeta::default(),
            rows: stream,
            table_path: Some(&table),
        })
        .unwrap();
    } else {
        SortedSnapshot::write(&snapshot, &index).unwrap();
    }
    let disk = DiskSnapshot::open(&snapshot).unwrap().unwrap();
    let mut restored = SummaryIndex::from_disk(Some(disk), 1);
    // Tests use one fixed capture threshold. Reads must never consult a clock.
    restored.raise_cold_before(100);
    (dir, restored, root_key, expected)
}

fn cold_filter(root: &RowKey) -> ListFilter {
    let mut filter = ListFilter::family(root.clone());
    filter.cold = true;
    filter
}

fn collect_pages(index: &SummaryIndex, filter: &ListFilter) -> (Vec<String>, Vec<SortKey>, usize) {
    let mut anchor = None;
    let mut rows = Vec::new();
    let mut keys = Vec::new();
    let mut bytes = 0;
    for _ in 0..128 {
        let page = index
            .read_page(anchor.as_ref(), ReadSide::After, false, 400, 256 * 1024, Some(filter))
            .unwrap();
        bytes += page.bytes_read;
        rows.extend(page.rows.iter().map(|row| row.chat_id.clone()));
        if let Some(key) = page.after_key.clone() {
            keys.push(key.clone());
        }
        if !page.has_after {
            return (rows, keys, bytes);
        }
        assert_ne!(anchor.as_ref(), page.after_key.as_ref(), "cold cursor must advance");
        anchor = page.after_key;
    }
    panic!("cold page cursor did not terminate")
}

#[test]
fn cold_family_table_matches_whole_snapshot_reference() {
    let (_dir, indexed, root, expected) = snapshot_fixture(true);
    let filter = cold_filter(&root);
    let (rows, _, bytes) = collect_pages(&indexed, &filter);
    let mut rows = rows;
    let mut expected = expected;
    rows.sort();
    expected.sort();
    assert_eq!(rows, expected);
    assert!(bytes <= 256 * 1024, "table reads exceeded one request budget");
}

#[test]
fn cold_table_prefix_failure_continues_with_the_pager_cursor() {
    let dir = tempfile::tempdir().unwrap();
    let snapshot = dir.path().join("index.snap");
    let table = dir.path().join("index.snap.kin");
    let root = closed("corrupt-root", 1);
    let mut index = SummaryIndex::new().apply(1, root.clone());
    for n in 0..381 {
        let mut row = closed(format!("corrupt-{n:03}"), 2);
        row.parent = Some(root.key());
        index = index.apply(n as u64 + 2, row);
    }
    SortedSnapshot::write_stream_generation_with_table(StreamGeneration {
        path: &snapshot,
        seq: index.seq(),
        log_offset: 0,
        log_name: None,
        covered_generation: 0,
        meta: SnapshotMeta::default(),
        rows: index.merged_rows(),
        table_path: Some(&table),
    })
    .unwrap();
    let mut sidecar = std::fs::OpenOptions::new().read(true).write(true).open(&table).unwrap();
    use std::io::{Read, Seek, SeekFrom, Write};
    sidecar.seek(SeekFrom::Start(4 * 4096)).unwrap();
    let mut byte = [0];
    sidecar.read_exact(&mut byte).unwrap();
    byte[0] ^= 1;
    sidecar.seek(SeekFrom::Start(4 * 4096)).unwrap();
    sidecar.write_all(&byte).unwrap();
    sidecar.sync_all().unwrap();

    let mut indexed = SummaryIndex::from_disk(DiskSnapshot::open(&snapshot).unwrap(), 1);
    indexed.raise_cold_before(100);
    let filter = cold_filter(&root.key());
    let before = snapshot::read_probe();
    let first =
        indexed.read_page(None, ReadSide::After, false, 400, PAGE_BYTES, Some(&filter)).unwrap();
    let after = snapshot::read_probe();
    assert_eq!(after.0 - before.0, first.bytes_read);
    assert_eq!(after.2 - before.2, 1);
    assert_eq!(first.rows.len(), 254);
    assert_eq!(first.after_key, first.rows.last().map(|row| SortKey::of(row)));
    assert!(first.closure, "every returned row is from the verified table prefix");
    assert!(first.has_after);
    assert!(first.bytes_read <= PAGE_BYTES);
    let continuation = first.after_key.clone().expect("verified prefix cursor");
    let second = indexed
        .read_page(Some(&continuation), ReadSide::After, false, 400, PAGE_BYTES, Some(&filter))
        .unwrap();
    assert!(!second.closure, "the next page uses the pager after set-aside");
    let mut ids: Vec<_> =
        first.rows.iter().chain(second.rows.iter()).map(|row| row.chat_id.clone()).collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 381);
    assert!(second.rows.iter().all(|row| !first.rows.iter().any(|prior| prior.key() == row.key())));
}

#[test]
fn cold_table_placement_failure_leaves_budget_for_the_pager() {
    let (dir, indexed, root, expected) = snapshot_fixture(true);
    let table = dir.path().join("index.snap.kin");
    let mut sidecar = std::fs::OpenOptions::new().read(true).write(true).open(table).unwrap();
    use std::io::{Read, Seek, SeekFrom, Write};
    sidecar.seek(SeekFrom::Start(2 * 4096)).unwrap();
    let mut byte = [0];
    sidecar.read_exact(&mut byte).unwrap();
    byte[0] ^= 1;
    sidecar.seek(SeekFrom::Start(2 * 4096)).unwrap();
    sidecar.write_all(&byte).unwrap();
    sidecar.sync_all().unwrap();

    let before = snapshot::read_probe();
    let page = indexed
        .read_page(None, ReadSide::After, false, 400, PAGE_BYTES, Some(&cold_filter(&root)))
        .unwrap();
    let after = snapshot::read_probe();
    assert_eq!(after.0 - before.0, page.bytes_read);
    assert_eq!(after.2 - before.2, 1);
    assert!(!page.closure);
    assert!(!page.rows.is_empty());
    assert!(page.bytes_read <= PAGE_BYTES);
    assert!(page.rows.iter().all(|row| expected.iter().any(|id| id == &row.chat_id)));
}

#[test]
fn snapshot_without_table_is_served_by_the_pager() {
    let (_dir, indexed, root, expected) = snapshot_fixture(false);
    let before = snapshot::read_probe();
    let (mut rows, _, bytes) = collect_pages(&indexed, &cold_filter(&root));
    let after = snapshot::read_probe();
    // The pager keeps its direct-kin semantics. The client follows each cold
    // row when a walk has any non-closure page (decision 392).
    let mut expected: Vec<_> =
        expected.into_iter().filter(|id| !id.starts_with("cold-grand-")).collect();
    rows.sort();
    expected.sort();
    assert_eq!(rows, expected);
    // Force several asks on a snapshot that never had a sidecar: losing the
    // saved seek position would restart the first page forever.
    let mut anchor = None;
    let mut paged = Vec::new();
    for _ in 0..16 {
        let before = snapshot::read_probe();
        let page = indexed
            .read_page(
                anchor.as_ref(),
                ReadSide::After,
                false,
                2,
                PAGE_BYTES,
                Some(&cold_filter(&root)),
            )
            .unwrap();
        assert_eq!(snapshot::read_probe().0 - before.0, page.bytes_read);
        paged.extend(page.rows.iter().map(|row| row.chat_id.clone()));
        if !page.has_after {
            break;
        }
        assert_ne!(anchor, page.after_key);
        anchor = page.after_key;
    }
    paged.sort();
    assert_eq!(paged, expected);
    assert_eq!(after.1, before.1, "no table served this request");
    assert!(bytes <= PAGE_BYTES);
    assert!(
        !indexed
            .read_page(None, ReadSide::After, false, 400, PAGE_BYTES, Some(&cold_filter(&root)))
            .unwrap()
            .closure
    );
}

#[test]
fn equal_activity_cursor_resumes_without_loss_or_duplication() {
    let dir = tempfile::tempdir().unwrap();
    let snapshot = dir.path().join("index.snap");
    let table = dir.path().join("index.snap.kin");
    let root = closed("tie-root", 1);
    let mut index = SummaryIndex::new().apply(1, root.clone());
    for n in 0..300 {
        let mut row = closed(format!("tie-{n:03}"), 3);
        row.parent = Some(root.key());
        index = index.apply(n as u64 + 2, row);
    }
    SortedSnapshot::write_stream_generation_with_table(StreamGeneration {
        path: &snapshot,
        seq: index.seq(),
        log_offset: 0,
        log_name: None,
        covered_generation: 0,
        meta: SnapshotMeta::default(),
        rows: index.merged_rows(),
        table_path: Some(&table),
    })
    .unwrap();
    let disk = DiskSnapshot::open(&snapshot).unwrap().unwrap();
    let mut indexed = SummaryIndex::from_disk(Some(disk), 1);
    indexed.raise_cold_before(100);
    let filter = cold_filter(&root.key());
    let first =
        indexed.read_page(None, ReadSide::After, false, 200, 256 * 1024, Some(&filter)).unwrap();
    assert_eq!(first.rows.len(), 200);
    assert!(first.closure);
    let second = indexed
        .read_page(first.after_key.as_ref(), ReadSide::After, false, 200, 256 * 1024, Some(&filter))
        .unwrap();
    assert_eq!(second.rows.len(), 100);
    assert!(second.closure);
    let mut ids: Vec<_> =
        first.rows.iter().chain(second.rows.iter()).map(|row| row.chat_id.clone()).collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 300);
    assert!(!second.has_after);
}

#[test]
fn hot_child_under_cold_row_is_reported_in_deeper() {
    let (_dir, mut indexed, root, _expected) = snapshot_fixture(true);
    let cold_parent = child(closed("cold-parent", 2), &Summary::new("family-root"));
    let mut hot = child(closed("hot-bridge", 200), &cold_parent);
    hot.state = "open".to_owned();
    indexed = indexed.apply(indexed.seq() + 1, hot);
    let mut filter = cold_filter(&root);
    filter.state = Some("closed".to_owned());
    let page =
        indexed.read_page(None, ReadSide::After, false, 400, 256 * 1024, Some(&filter)).unwrap();
    assert!(page.rows.iter().any(|row| row.chat_id == "cold-parent"));
    assert!(page.deeper.iter().any(|key| key.row.chat_id.as_ref() == "cold-parent"));
}

#[test]
fn stale_in_memory_edge_does_not_list_a_moved_row() {
    let (_dir, mut indexed, root, _expected) = snapshot_fixture(true);
    indexed = indexed.apply(indexed.seq() + 1, closed("other-root", 200));
    let mut moved = closed("cold-parent", 2);
    moved.parent = Some(RowKey::new("local", "other-root"));
    indexed = indexed.apply(indexed.seq() + 1, moved);
    let page = indexed
        .read_page(None, ReadSide::After, false, 400, 256 * 1024, Some(&cold_filter(&root)))
        .unwrap();
    assert!(!page.rows.iter().any(|row| row.chat_id == "cold-parent"));
    assert!(!page.rows.iter().any(|row| row.chat_id == "cold-grand-0"));
    assert!(!page.rows.iter().any(|row| row.chat_id == "cold-grand-1"));
}

#[test]
fn cold_unread_checks_the_table_only_on_the_last_hot_page() {
    let (_dir, mut indexed, root, _expected) = snapshot_fixture(true);
    for id in ["hot-a", "hot-b"] {
        let mut row = closed(id, 200);
        row.parent = Some(root.clone());
        indexed = indexed.apply(indexed.seq() + 1, row);
    }
    let filter = ListFilter::family(root);
    let before = snapshot::read_probe();
    let first =
        indexed.read_page(None, ReadSide::After, false, 1, PAGE_BYTES, Some(&filter)).unwrap();
    let middle = snapshot::read_probe();
    assert!(first.has_after);
    assert_eq!(first.rows.len(), 1);
    assert_eq!(middle, before, "intermediate hot page must not read the table");
    let last = indexed
        .read_page(first.after_key.as_ref(), ReadSide::After, false, 1, PAGE_BYTES, Some(&filter))
        .unwrap();
    let after = snapshot::read_probe();
    assert!(!last.has_after);
    assert!(last.cold_unread);
    assert_eq!(last.rows.len(), 1);
    assert_eq!(after.1, before.1 + 1);
    assert_eq!(after.2, before.2);
}

#[test]
fn cold_depth_64_entry_names_the_next_family_walk() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.snap");
    let table_path = dir.path().join("index.snap.kin");
    let root = closed("depth-root", 1);
    let root_key = root.key();
    let mut parent = root_key.clone();
    let mut index = SummaryIndex::new().apply(1, root);
    for depth in 1..=65 {
        let mut row = closed(format!("depth-{depth:02}"), 2);
        row.parent = Some(parent);
        parent = row.key();
        index = index.apply(depth + 1, row);
    }
    SortedSnapshot::write_stream_generation_with_table(StreamGeneration {
        path: &path,
        seq: index.seq(),
        log_offset: 0,
        log_name: None,
        covered_generation: 0,
        meta: SnapshotMeta::default(),
        rows: index.merged_rows(),
        table_path: Some(&table_path),
    })
    .unwrap();
    let mut restored = SummaryIndex::from_disk(DiskSnapshot::open(path).unwrap(), 1);
    restored.raise_cold_before(100);
    let page = restored
        .read_page(None, ReadSide::After, false, 400, PAGE_BYTES, Some(&cold_filter(&root_key)))
        .unwrap();
    assert_eq!(page.rows.len(), 64);
    assert_eq!(page.deeper.len(), 1);
    let continuation = page.deeper.first().unwrap();
    assert_eq!(continuation.row.chat_id.as_ref(), "depth-64");
    let next = restored
        .read_page(
            None,
            ReadSide::After,
            false,
            400,
            PAGE_BYTES,
            Some(&cold_filter(&continuation.row)),
        )
        .unwrap();
    assert_eq!(next.rows.len(), 1);
    assert_eq!(next.rows.first().unwrap().chat_id, "depth-65");
}

#[test]
fn cold_family_random_forest_matches_whole_pager_reference() {
    fn build(with_table: bool) -> (TempDir, SummaryIndex, RowKey, Vec<String>) {
        let dir = tempfile::tempdir().unwrap();
        let snapshot = dir.path().join("index.snap");
        let table = dir.path().join("index.snap.kin");
        let root = closed("forest-root", 1);
        let root_key = root.key();
        let mut rows = vec![root];
        // A deterministic LCG gives a repeatable forest with both shallow and
        // deep branches while keeping every generated parent earlier in the
        // stream (so the reference walk cannot cycle).
        let mut rng = 0x9e37_79b9_u64;
        let mut next_random = || {
            rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1);
            rng
        };
        for n in 0..256 {
            let mut row = closed(format!("forest-{n:03}"), 2 + (n % 17) as u64);
            let parent = if n < 4 || n % 5 == 0 {
                root_key.clone()
            } else {
                RowKey::new("local", format!("forest-{:03}", (next_random() as usize) % n))
            };
            row.parent = Some(parent);
            rows.push(row);
        }
        let mut parents = std::collections::HashMap::new();
        for row in &rows {
            parents.insert(row.key(), row.parent.clone());
        }
        let mut expected = Vec::new();
        for row in rows.iter().skip(1) {
            let mut cursor = row.parent.clone();
            let mut under_root = false;
            for _ in 0..MAX_KIN_DEPTH {
                let Some(parent) = cursor else { break };
                if parent == root_key {
                    under_root = true;
                    break;
                }
                cursor = parents.get(&parent).cloned().flatten();
            }
            if under_root {
                expected.push(row.chat_id.clone());
            }
        }
        let mut index = SummaryIndex::new();
        for (seq, row) in rows.into_iter().enumerate() {
            index = index.apply(seq as u64 + 1, row);
        }
        if with_table {
            SortedSnapshot::write_stream_generation_with_table(StreamGeneration {
                path: &snapshot,
                seq: index.seq(),
                log_offset: 0,
                log_name: None,
                covered_generation: 0,
                meta: SnapshotMeta::default(),
                rows: index.merged_rows(),
                table_path: Some(&table),
            })
            .unwrap();
        } else {
            SortedSnapshot::write(&snapshot, &index).unwrap();
        }
        let disk = DiskSnapshot::open(snapshot).unwrap().unwrap();
        let mut restored = SummaryIndex::from_disk(Some(disk), 1);
        restored.raise_cold_before(100);
        (dir, restored, root_key, expected)
    }
    let (_table_dir, table, root, mut fixture_expected) = build(true);
    let disk = table.disk().unwrap();
    let mut anchor = None;
    let mut all = std::collections::HashMap::new();
    loop {
        let piece =
            disk.read_piece(anchor.as_ref(), ReadSide::After, false, 37, PAGE_BYTES).unwrap();
        let last = piece.rows.last().map(|row| SortKey::of(row));
        for row in piece.rows {
            all.insert(row.key(), row);
        }
        if !piece.has_after {
            break;
        }
        assert!(last.is_some() && last != anchor);
        anchor = last;
    }
    assert_eq!(all.len(), 257);
    let mut expected = Vec::new();
    for row in all.values() {
        let mut parent = row.parent.clone();
        for _ in 0..MAX_KIN_DEPTH {
            let Some(key) = parent else {
                break;
            };
            if key == root {
                expected.push(row.chat_id.clone());
                break;
            }
            parent = all.get(&key).and_then(|ancestor| ancestor.parent.clone());
        }
    }
    let (mut indexed_rows, _, _) = collect_pages(&table, &cold_filter(&root));
    indexed_rows.sort();
    expected.sort();
    fixture_expected.sort();
    assert_eq!(expected, fixture_expected);
    assert_eq!(indexed_rows, expected);
}

#[test]
fn cold_table_reply_byte_cut_preserves_closure_and_continuation() {
    let (_directory, index, root, _expected) = snapshot_fixture(true);
    let filter = cold_filter(&root);
    let complete =
        index.read_page(None, ReadSide::After, false, 400, PAGE_BYTES, Some(&filter)).unwrap();
    let first_row_bytes = complete.rows.first().unwrap().encoded_len() + 1;
    let first =
        index.read_page(None, ReadSide::After, false, 400, first_row_bytes, Some(&filter)).unwrap();
    assert_eq!(first.rows.len(), 1);
    assert!(first.closure && first.has_after);
    let rest = index
        .read_page(first.after_key.as_ref(), ReadSide::After, false, 400, PAGE_BYTES, Some(&filter))
        .unwrap();
    assert!(rest.closure && !rest.has_after);
    let keys: Vec<_> = first.rows.iter().chain(rest.rows.iter()).map(|row| row.key()).collect();
    assert_eq!(keys, complete.rows.iter().map(|row| row.key()).collect::<Vec<_>>());
}
