use super::*;
use crate::index::{ForkOf, RowKey, Summary};
use std::cmp::Ordering;
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

const TEST_PAGE_BYTES: usize = 4096;
const TEST_ENTRY_BYTES: usize = 32;
const TEST_ENTRIES_PER_PAGE: usize = 127;
const TEST_DATA_END: u64 = 1 << 40;
const TEST_ROW_LEN: usize = 128;
const TEST_HEAD_CRC: u32 = 0x1357_9bdf;

fn row(id: impl Into<String>, activity: u64) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = activity;
    row.state = "closed".to_owned();
    row
}

fn offset(index: usize) -> u64 {
    4096 + index as u64 * 256
}

fn binding(seq: u64, count: u64, head_crc: u32) -> Binding {
    Binding { head_crc, seq, count, data_end: TEST_DATA_END }
}

fn write_table(rows: &[Summary], seq: u64, head_crc: u32) -> (tempfile::TempDir, PathBuf) {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("index.snap.kin");
    let mut builder = Builder::new().unwrap();
    for (index, row) in rows.iter().enumerate() {
        builder.push(row, offset(index), TEST_ROW_LEN).unwrap();
    }
    builder.write(&path, head_crc, seq, rows.len() as u64, TEST_DATA_END).unwrap();
    (directory, path)
}

fn open_table(path: &Path, seq: u64, count: u64, head_crc: u32) -> Table {
    Table::open(path, binding(seq, count, head_crc)).unwrap().expect("valid kin table")
}

fn entry_order(left: &Entry, right: &Entry) -> Ordering {
    (left.hash, left.offset, left.check, left.depth, left.kind, left.activity, left.len).cmp(&(
        right.hash,
        right.offset,
        right.check,
        right.depth,
        right.kind,
        right.activity,
        right.len,
    ))
}

fn entries(table: &Table) -> Vec<Entry> {
    let pages = table.header.packed_entries.div_ceil(TEST_ENTRIES_PER_PAGE as u64);
    let mut entries = Vec::new();
    for page_index in
        u64::from(table.header.directory_pages)..u64::from(table.header.directory_pages) + pages
    {
        let page = table.read_page(page_index).expect("entry page");
        for index in 0..TEST_ENTRIES_PER_PAGE {
            let start = index * TEST_ENTRY_BYTES;
            let entry = Entry::decode(&page[start..start + TEST_ENTRY_BYTES]).unwrap();
            if entry.kind != 0 {
                entries.push(entry);
            }
        }
    }
    entries
}

fn expected_entries(rows: &[Summary]) -> Vec<Entry> {
    let by_key: BTreeMap<_, _> = rows.iter().map(|row| (row.key(), row)).collect();
    let mut expected = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        let eligible = !row.pinned && !row.is_live();
        if let Some(mut ancestor) = row.parent.clone()
            && ancestor != row.key()
        {
            for depth in 1..=MAX_DEPTH {
                if ancestor == row.key() {
                    break;
                }
                let (hash, check) = key_fingerprint(&ancestor, FAMILY_KIND);
                if eligible {
                    expected.push(Entry {
                        hash,
                        activity: row.last_activity,
                        offset: offset(index),
                        check,
                        len: TEST_ROW_LEN as u16,
                        depth,
                        kind: FAMILY_KIND,
                    });
                }
                let Some(parent) = by_key.get(&ancestor) else { break };
                let Some(next) = parent.parent.clone() else { break };
                ancestor = next;
            }
        }
        if eligible && let Some(fork) = &row.fork_of {
            let (hash, check) = key_fingerprint(&fork.key, FORK_KIND);
            expected.push(Entry {
                hash,
                activity: row.last_activity,
                offset: offset(index),
                check,
                len: TEST_ROW_LEN as u16,
                depth: 1,
                kind: FORK_KIND,
            });
        }
    }
    expected.sort_unstable_by(entry_order);
    expected
}

fn assert_rejected(path: &Path, bind: Binding) {
    match Table::open(path, bind) {
        Ok(None) | Err(_) => {}
        Ok(Some(_)) => panic!("mismatched kin binding was accepted"),
    }
}

fn forest() -> Vec<Summary> {
    let mut rows: Vec<Summary> = Vec::new();
    let mut state = 0x9e37_79b9_u64;
    for index in 0..96 {
        let mut row = row(format!("forest-{index:03}"), index as u64 + 1);
        if index > 0 {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
            let parent = (state as usize) % index;
            row.parent = Some(rows[parent].key());
        }
        if index % 13 == 0 {
            row.state = "running".to_owned();
        }
        if index % 17 == 0 {
            row.pinned = true;
        }
        rows.push(row);
    }

    let mut root = row("chain-000", 10_000);
    root.pinned = true;
    rows.push(root);
    let mut parent = rows.last().unwrap().key();
    for depth in 1..=70 {
        let mut next = row(format!("chain-{depth:03}"), 10_000 + depth as u64);
        next.parent = Some(parent);
        if depth == 17 {
            next.pinned = true;
        }
        if depth == 29 {
            next.state = "running".to_owned();
        }
        parent = next.key();
        rows.push(next);
    }

    let mut self_parent = row("self-parent", 20_000);
    self_parent.parent = Some(self_parent.key());
    rows.push(self_parent);
    let mut cycle_a = row("cycle-a", 20_001);
    let mut cycle_b = row("cycle-b", 20_002);
    cycle_a.parent = Some(cycle_b.key());
    cycle_b.parent = Some(cycle_a.key());
    rows.extend([cycle_a, cycle_b]);

    let fork_target = RowKey::new("local", "fork-target");
    let mut cold_fork = row("cold-fork", 20_003);
    cold_fork.fork_of = Some(ForkOf { key: fork_target.clone(), seq: 7 });
    rows.push(cold_fork);
    let mut live_fork = row("live-fork", 20_004);
    live_fork.state = "running".to_owned();
    live_fork.fork_of = Some(ForkOf { key: fork_target.clone(), seq: 8 });
    rows.push(live_fork);
    let mut pinned_fork = row("pinned-fork", 20_005);
    pinned_fork.pinned = true;
    pinned_fork.fork_of = Some(ForkOf { key: fork_target, seq: 9 });
    rows.push(pinned_fork);
    rows
}

#[test]
fn forest_entries_match_ancestor_oracle_with_depth_and_hot_bridges() {
    let rows = forest();
    let (_directory, path) = write_table(&rows, 42, TEST_HEAD_CRC);
    let table = open_table(&path, 42, rows.len() as u64, TEST_HEAD_CRC);
    let mut actual = entries(&table);
    actual.sort_unstable_by(entry_order);
    assert_eq!(actual, expected_entries(&rows));
    assert!(actual.iter().any(|entry| entry.depth == MAX_DEPTH));
    assert!(!actual.iter().any(|entry| entry.depth > MAX_DEPTH));
}

#[test]
fn cycle_closure_deduplicates_nearest_ancestors_without_self_rows() {
    let mut cycle_a = row("cycle-a", 1);
    let mut cycle_b = row("cycle-b", 2);
    let mut child = row("cycle-child", 3);
    cycle_a.parent = Some(cycle_b.key());
    cycle_b.parent = Some(cycle_a.key());
    child.parent = Some(cycle_b.key());
    let rows = [cycle_a.clone(), cycle_b.clone(), child];
    let (_directory, path) = write_table(&rows, 44, TEST_HEAD_CRC);
    let table = open_table(&path, 44, rows.len() as u64, TEST_HEAD_CRC);
    let actual = entries(&table);

    let family = |row_index: usize, ancestor: &RowKey, depth: u8| {
        let (hash, check) = key_fingerprint(ancestor, FAMILY_KIND);
        actual.iter().any(|entry| {
            entry.kind == FAMILY_KIND
                && entry.offset == offset(row_index)
                && entry.hash == hash
                && entry.check == check
                && entry.depth == depth
        })
    };
    assert!(family(0, &cycle_b.key(), 1));
    assert!(family(1, &cycle_a.key(), 1));
    assert!(family(2, &cycle_b.key(), 1));
    assert!(family(2, &cycle_a.key(), 2));
    assert_eq!(actual.iter().filter(|entry| entry.kind == FAMILY_KIND).count(), 4);
    for (index, row) in rows.iter().enumerate() {
        let (hash, check) = key_fingerprint(&row.key(), FAMILY_KIND);
        assert!(!actual.iter().any(|entry| {
            entry.kind == FAMILY_KIND
                && entry.offset == offset(index)
                && entry.hash == hash
                && entry.check == check
        }));
    }
}

#[test]
fn fork_self_edges_are_excluded_but_other_sources_are_retained() {
    let mut self_fork = row("fork-self", 1);
    self_fork.fork_of = Some(ForkOf { key: self_fork.key(), seq: 1 });
    let source = RowKey::new("local", "fork-source");
    let mut other_fork = row("fork-other", 2);
    other_fork.fork_of = Some(ForkOf { key: source.clone(), seq: 2 });
    let rows = [self_fork, other_fork];
    let (_directory, path) = write_table(&rows, 45, TEST_HEAD_CRC);
    let table = open_table(&path, 45, rows.len() as u64, TEST_HEAD_CRC);
    let actual = entries(&table);
    let (source_hash, source_check) = key_fingerprint(&source, FORK_KIND);
    assert_eq!(actual.iter().filter(|entry| entry.kind == FORK_KIND).count(), 1);
    assert!(actual.iter().any(|entry| {
        entry.kind == FORK_KIND
            && entry.offset == offset(1)
            && entry.hash == source_hash
            && entry.check == source_check
            && entry.depth == 1
    }));
    let (self_hash, self_check) = key_fingerprint(&rows[0].key(), FORK_KIND);
    assert!(!actual.iter().any(|entry| {
        entry.kind == FORK_KIND && entry.hash == self_hash && entry.check == self_check
    }));
}

#[test]
fn self_parent_has_no_self_entry_but_children_still_use_it() {
    let mut self_parent = row("self-parent-explicit", 1);
    self_parent.parent = Some(self_parent.key());
    let mut child = row("self-parent-child", 2);
    child.parent = Some(self_parent.key());
    let rows = [self_parent.clone(), child];
    let (_directory, path) = write_table(&rows, 46, TEST_HEAD_CRC);
    let table = open_table(&path, 46, rows.len() as u64, TEST_HEAD_CRC);
    let actual = entries(&table);
    let (parent_hash, parent_check) = key_fingerprint(&self_parent.key(), FAMILY_KIND);
    assert_eq!(actual.len(), 1);
    assert_eq!(actual[0].offset, offset(1));
    assert_eq!(actual[0].depth, 1);
    assert_eq!(actual[0].hash, parent_hash);
    assert_eq!(actual[0].check, parent_check);
}

#[test]
fn fingerprint_fixed_vector_is_stable() {
    let key = RowKey::new("local", "chat-1");
    assert_eq!(key_fingerprint(&key, FAMILY_KIND), (0xd22b47804e9d17c0, 0xb87b4fdf));
}

#[test]
fn cold_descendant_keeps_ancestor_path_through_hot_parent() {
    let mut root = row("bridge-root", 1);
    root.parent = Some(RowKey::new("local", "outside"));
    let mut parent = row("bridge-parent", 2);
    parent.state = "running".to_owned();
    parent.parent = Some(root.key());
    let mut child = row("bridge-child", 3);
    child.parent = Some(parent.key());
    let rows = [root, parent, child];
    let (_directory, path) = write_table(&rows, 43, TEST_HEAD_CRC);
    let table = open_table(&path, 43, rows.len() as u64, TEST_HEAD_CRC);
    let actual = entries(&table);
    let child_offset = offset(2);
    let child_entries: Vec<_> =
        actual.iter().filter(|entry| entry.offset == child_offset).collect();
    assert_eq!(child_entries.len(), 3);
    assert!(child_entries.iter().any(|entry| entry.depth == 1));
    assert!(child_entries.iter().any(|entry| entry.depth == 2));
    assert!(child_entries.iter().any(|entry| entry.depth == 3));
}

#[test]
fn parent_mutation_replaces_the_old_ancestor_chain() {
    let root_a = row("parent-a", 1);
    let root_b = row("parent-b", 2);
    let mut child_a = row("mutable-child", 3);
    child_a.parent = Some(root_a.key());
    let first_rows = [root_a.clone(), root_b.clone(), child_a];
    let (_first_directory, first_path) = write_table(&first_rows, 50, TEST_HEAD_CRC);
    let first_table = open_table(&first_path, 50, first_rows.len() as u64, TEST_HEAD_CRC);
    let first = entries(&first_table);
    let old_hash = key_fingerprint(&root_a.key(), FAMILY_KIND).0;
    let new_hash = key_fingerprint(&root_b.key(), FAMILY_KIND).0;
    assert!(first.iter().any(|entry| entry.hash == old_hash));
    assert!(!first.iter().any(|entry| entry.hash == new_hash));

    let mut child_b = row("mutable-child", 3);
    child_b.parent = Some(root_b.key());
    let second_rows = [root_a, root_b, child_b];
    let (_second_directory, second_path) = write_table(&second_rows, 51, TEST_HEAD_CRC);
    let second_table = open_table(&second_path, 51, second_rows.len() as u64, TEST_HEAD_CRC);
    let second = entries(&second_table);
    assert!(second.iter().any(|entry| entry.hash == new_hash));
    assert!(!second.iter().any(|entry| entry.hash == old_hash));
}

#[test]
fn another_snapshot_binding_is_rejected_without_poisoning_a_valid_table() {
    let rows = [row("one", 1), row("two", 2)];
    let (_directory, path) = write_table(&rows, 11, TEST_HEAD_CRC);
    assert_rejected(&path, binding(12, rows.len() as u64, TEST_HEAD_CRC));
    assert_rejected(&path, binding(11, rows.len() as u64 + 1, TEST_HEAD_CRC));
    assert_rejected(&path, binding(11, rows.len() as u64, TEST_HEAD_CRC ^ 1));
    let table = Table::open(&path, binding(11, rows.len() as u64, TEST_HEAD_CRC))
        .unwrap()
        .expect("matching binding remains usable");
    assert_eq!(table.header.entries, 0);
}

#[test]
fn damaged_page_disables_once_and_short_page_is_not_retried() {
    let mut rows = Vec::with_capacity(160);
    let root = row("page-root", 1);
    let root_key = root.key();
    rows.push(root);
    for index in 0..160 {
        let mut child = row(format!("page-child-{index:03}"), index as u64 + 2);
        child.parent = Some(root_key.clone());
        rows.push(child);
    }
    let (_directory, path) = write_table(&rows, 7, TEST_HEAD_CRC);
    let table = open_table(&path, 7, rows.len() as u64, TEST_HEAD_CRC);
    let first_data_page = u64::from(table.header.directory_pages);
    let mut file = OpenOptions::new().write(true).open(&path).unwrap();
    file.seek(SeekFrom::Start((1 + first_data_page) * TEST_PAGE_BYTES as u64 + 8)).unwrap();
    file.write_all(&[0x5a]).unwrap();
    drop(file);
    assert!(table.read_page(first_data_page).is_none());
    assert_eq!(table.failures(), 1);
    assert!(table.read_page(first_data_page).is_none());
    assert_eq!(table.failures(), 1);
    assert!(!table.is_usable());

    let (_directory, short_path) = write_table(&rows, 8, TEST_HEAD_CRC);
    let short = open_table(&short_path, 8, rows.len() as u64, TEST_HEAD_CRC);
    let first_data_page = u64::from(short.header.directory_pages);
    OpenOptions::new()
        .write(true)
        .open(&short_path)
        .unwrap()
        .set_len((1 + first_data_page) * TEST_PAGE_BYTES as u64 + 100)
        .unwrap();
    assert!(short.read_page(first_data_page).is_none());
    assert_eq!(short.failures(), 1);
    assert!(short.read_page(first_data_page).is_none());
    assert_eq!(short.failures(), 1);
}

#[test]
fn empty_table_is_header_only() {
    let (_directory, path) = write_table(&[], 1, TEST_HEAD_CRC);
    assert_eq!(fs::metadata(&path).unwrap().len(), TEST_PAGE_BYTES as u64);
    let table = open_table(&path, 1, 0, TEST_HEAD_CRC);
    assert_eq!(table.header.entries, 0);
    assert!(table.is_usable());
}

fn test_slot_for(hash: u64, slots: usize) -> usize {
    if slots == 1 { 0 } else { (hash >> (64 - slots.trailing_zeros())) as usize }
}

#[test]
fn packed_buckets_are_page_aligned_and_within_the_size_bound() {
    let counts = [120usize, 120, 130];
    let entry_count = counts.iter().sum::<usize>();
    let slots = entry_count.div_ceil(64).next_power_of_two().max(1);
    let mut roots = Vec::new();
    let mut used_slots = HashSet::new();
    let mut candidate = 0;
    while roots.len() < counts.len() {
        let key = RowKey::new("local", format!("bucket-root-{candidate}"));
        candidate += 1;
        let slot = test_slot_for(key_fingerprint(&key, FAMILY_KIND).0, slots);
        if used_slots.insert(slot) {
            roots.push(key);
        }
    }
    let mut rows = Vec::new();
    for (root_index, (root_key, count)) in roots.iter().zip(counts).enumerate() {
        rows.push(row(root_key.chat_id.to_string(), root_index as u64));
        for child_index in 0..count {
            let mut child = row(
                format!("bucket-child-{root_index:02}-{child_index:03}"),
                1_000 + child_index as u64,
            );
            child.parent = Some(root_key.clone());
            rows.push(child);
        }
    }
    let (_directory, path) = write_table(&rows, 99, TEST_HEAD_CRC);
    let table = open_table(&path, 99, rows.len() as u64, TEST_HEAD_CRC);
    let page = table.read_page(0).expect("directory page");
    for slot in 0..slots {
        let at = slot * 8;
        let start = u32::from_le_bytes(page[at..at + 4].try_into().unwrap()) as usize;
        let len = u32::from_le_bytes(page[at + 4..at + 8].try_into().unwrap()) as usize;
        if len == 0 {
            continue;
        }
        assert!(len <= TEST_ENTRIES_PER_PAGE || start.is_multiple_of(TEST_ENTRIES_PER_PAGE));
        assert!(
            start % TEST_ENTRIES_PER_PAGE + len <= TEST_ENTRIES_PER_PAGE
                || len > TEST_ENTRIES_PER_PAGE
        );
    }
    assert_eq!(table.header.entries as usize, entry_count);
    assert!(
        fs::metadata(&path).unwrap().len() <= entry_count as u64 * 64 + 3 * TEST_PAGE_BYTES as u64
    );
}
