use super::{DiskSnapshot, PAGE_BYTES, SortedSnapshot};
use crate::index::{
    FolderKey, ListFilter, ReadSide, RowKey, SortKey, Summary, SummaryIndex, is_fatal_snapshot_read,
};
use std::fs;

fn row(id: &str, activity: u64) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = activity;
    row.state = "closed".to_owned();
    row
}

fn write_rows(path: &std::path::Path, count: usize) -> SummaryIndex {
    let mut index = SummaryIndex::new();
    for n in 0..count {
        index = index.apply(n as u64 + 1, row(&format!("row-{n:04}"), (count - n) as u64));
    }
    SortedSnapshot::write(path, &index).unwrap();
    index
}

fn damage_frame(path: &std::path::Path, ordinal: usize) {
    let mut bytes = fs::read(path).unwrap();
    let mut offset = super::HEADER_BYTES;
    for current in 0..=ordinal {
        let body =
            u32::from_le_bytes(bytes.get(offset..offset + 4).unwrap().try_into().unwrap()) as usize;
        let frame = body + 12;
        if current == ordinal {
            *bytes.get_mut(offset + 8).unwrap() ^= 1;
        }
        offset += frame;
    }
    fs::write(path, bytes).unwrap();
}

fn damage_length(path: &std::path::Path) {
    let mut bytes = fs::read(path).unwrap();
    let start = super::HEADER_BYTES;
    bytes.get_mut(start..start + 4).unwrap().copy_from_slice(&u32::MAX.to_le_bytes());
    fs::write(path, bytes).unwrap();
}

fn damage_frames(path: &std::path::Path, count: usize) {
    let mut bytes = fs::read(path).unwrap();
    let mut offset = super::HEADER_BYTES;
    for _ in 0..count {
        let body =
            u32::from_le_bytes(bytes.get(offset..offset + 4).unwrap().try_into().unwrap()) as usize;
        *bytes.get_mut(offset + 8).unwrap() ^= 1;
        offset += body + 12;
    }
    fs::write(path, bytes).unwrap();
}

#[test]
fn first_page_skips_a_complete_bad_frame_and_keeps_physical_flags() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("index.snap");
    let mut index = SummaryIndex::new();
    for (id, activity) in [("first", 3), ("bad", 2), ("last", 1)] {
        index = index.apply(activity, row(id, activity));
    }
    SortedSnapshot::write(&path, &index).unwrap();

    let mut bytes = fs::read(&path).unwrap();
    let start = super::HEADER_BYTES;
    let first_body =
        u32::from_le_bytes(bytes.get(start..start + 4).unwrap().try_into().unwrap()) as usize;
    let first_frame = first_body + 12;
    let second = start + first_frame;
    *bytes.get_mut(second + 8).unwrap() ^= 1;
    fs::write(&path, bytes).unwrap();

    let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
    let page = snapshot.first_rows(2, PAGE_BYTES).unwrap();
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["first", "last"]
    );
    assert_eq!(page.first_ordinal, 0);
    assert!(!page.has_before);
    assert!(!page.has_after);
    assert_eq!(page.physical_count, 3);
    assert_eq!(page.next_ordinal, 3);
}

#[test]
fn around_page_flags_use_the_selected_physical_span() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("index.snap");
    let mut index = SummaryIndex::new();
    for n in 0..10 {
        index = index.apply(n + 1, row(&format!("row-{n}"), 10 - n));
    }
    SortedSnapshot::write(&path, &index).unwrap();
    let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
    let anchor = SortKey::of(&index.get("row-5").unwrap());
    let page = snapshot.read_piece(Some(&anchor), ReadSide::Around, true, 4, PAGE_BYTES).unwrap();
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["row-3", "row-4", "row-5", "row-6"]
    );
    assert!(page.has_before);
    assert!(page.has_after);
}

#[test]
fn damaged_rows_at_each_sparse_position_preserve_forward_and_backward_pages() {
    let directory = tempfile::tempdir().unwrap();
    let source_path = directory.path().join("source.snap");
    let source_index = write_rows(&source_path, 300);
    let source = DiskSnapshot::open(&source_path).unwrap().unwrap();
    let bytes = fs::read(&source_path).unwrap();
    let checkpoint_at = source.directory_offset() as usize + super::CHECKPOINT_BYTES;
    let checkpoint = super::Checkpoint::decode(
        bytes.get(checkpoint_at..checkpoint_at + super::CHECKPOINT_BYTES).unwrap(),
    )
    .unwrap();
    for damaged_ordinal in [0, checkpoint.ordinal as usize, 150, 299] {
        let damaged_path = directory.path().join(format!("damaged-{damaged_ordinal}.snap"));
        fs::copy(&source_path, &damaged_path).unwrap();
        damage_frame(&damaged_path, damaged_ordinal);
        let damaged = DiskSnapshot::open(&damaged_path).unwrap().unwrap();
        let mut expected_index = SummaryIndex::new();
        for ordinal in 0..300 {
            if ordinal != damaged_ordinal {
                let row = source_index.get(&format!("row-{ordinal:04}")).unwrap();
                expected_index = expected_index.apply(ordinal as u64 + 1, row.as_ref().clone());
            }
        }
        let clean_path = directory.path().join(format!("clean-{damaged_ordinal}.snap"));
        SortedSnapshot::write(&clean_path, &expected_index).unwrap();
        let clean = DiskSnapshot::open(&clean_path).unwrap().unwrap();
        for ordinal in 0..300 {
            let anchor = SortKey::of(&source_index.get(&format!("row-{ordinal:04}")).unwrap());
            for inclusive in [false, true] {
                for side in [ReadSide::After, ReadSide::Before] {
                    let expected =
                        clean.read_piece(Some(&anchor), side, inclusive, 5, PAGE_BYTES).unwrap();
                    let actual =
                        damaged.read_piece(Some(&anchor), side, inclusive, 5, PAGE_BYTES).unwrap();
                    let ids = |rows: &[std::sync::Arc<Summary>]| {
                        rows.iter().map(|row| row.chat_id.clone()).collect::<Vec<_>>()
                    };
                    assert_eq!(
                        ids(&actual.rows),
                        ids(&expected.rows),
                        "damaged {damaged_ordinal}, anchor {ordinal}, side {side:?}, inclusive {inclusive}"
                    );
                }
                let left = clean.seek_position(&anchor, inclusive).unwrap();
                let right = damaged.seek_position(&anchor, inclusive).unwrap();
                let expected = clean.rows_at(left.offset, left.ordinal, 1, PAGE_BYTES).unwrap();
                let actual = damaged.rows_at(right.offset, right.ordinal, 1, PAGE_BYTES).unwrap();
                assert_eq!(
                    actual.rows.first().map(|row| &row.chat_id),
                    expected.rows.first().map(|row| &row.chat_id)
                );
            }
        }
    }
}

#[test]
fn bad_length_is_a_typed_fatal_error() {
    let directory = tempfile::tempdir().unwrap();

    let bad_path = directory.path().join("bad-length.snap");
    write_rows(&bad_path, 2);
    damage_length(&bad_path);
    let snapshot = DiskSnapshot::open(&bad_path).unwrap().unwrap();
    let result = snapshot.first_rows(1, PAGE_BYTES);
    assert!(result.is_err());
    let Err(error) = result else { return };
    assert!(is_fatal_snapshot_read(&error));
}

#[test]
fn long_corrupt_run_stops_after_a_bounded_scan() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("long-corrupt.snap");
    write_rows(&path, 4_096);
    damage_frames(&path, 4_096);
    let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
    assert!(snapshot.head.data_end - super::HEADER_BYTES as u64 > PAGE_BYTES as u64);
    assert!(
        snapshot.rows().any(|result| result.is_err_and(|error| is_fatal_snapshot_read(&error)))
    );
}

#[test]
fn wholly_damaged_terminal_piece_has_no_false_continuation() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("all-corrupt.snap");
    write_rows(&path, 3);
    damage_frames(&path, 3);
    let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
    let page = snapshot.first_rows(3, PAGE_BYTES).unwrap();
    assert!(page.rows.is_empty());
    assert!(!page.has_before);
    assert!(!page.has_after);
}

#[test]
fn cold_folder_and_family_reads_cross_a_damaged_frame() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("filtered.snap");
    let mut index = SummaryIndex::new();
    let root = row("root", 4);
    let mut child = row("child", 3);
    child.parent = Some(root.key());
    child.folder = Some("one".to_owned());
    let mut sibling = row("sibling", 2);
    sibling.folder = Some("one".to_owned());
    for (seq, item) in [(1, root), (2, child), (3, sibling)] {
        index = index.apply(seq, item);
    }
    SortedSnapshot::write(&path, &index).unwrap();
    damage_frame(&path, 1);
    let disk = SummaryIndex::from_disk(DiskSnapshot::open(&path).unwrap(), 3);
    let folder = ListFilter {
        cold: true,
        folder: Some(FolderKey::new("local", "one")),
        ..ListFilter::default()
    };
    let page = disk.read_page(None, ReadSide::After, false, 4, PAGE_BYTES, Some(&folder)).unwrap();
    assert_eq!(page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(), ["sibling"]);
    assert!(!page.has_after);
    let family = ListFilter {
        cold: true,
        family: Some(RowKey::new("local", "root")),
        ..ListFilter::default()
    };
    let page = disk.read_page(None, ReadSide::After, false, 4, PAGE_BYTES, Some(&family)).unwrap();
    assert!(page.rows.is_empty());
    assert!(!page.has_after);
}

#[test]
fn malformed_snapshot_structure_is_one_typed_error() {
    let directory = tempfile::tempdir().unwrap();
    for fault in ["head", "tail", "checkpoint", "trailer"] {
        let path = directory.path().join(format!("{fault}.snap"));
        let index = write_rows(&path, 300);
        let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
        let mut bytes = fs::read(&path).unwrap();
        match fault {
            "head" => bytes.truncate(100),
            "tail" => {
                bytes.pop();
            }
            "checkpoint" => {
                *bytes.get_mut(snapshot.directory_offset() as usize + 10).unwrap() ^= 1;
            }
            "trailer" => {
                let body =
                    u32::from_le_bytes(bytes.get(4096..4100).unwrap().try_into().unwrap()) as usize;
                *bytes.get_mut(4096 + 8 + body).unwrap() ^= 1;
            }
            _ => {}
        }
        fs::write(&path, bytes).unwrap();
        let error = match DiskSnapshot::open(&path) {
            Err(error) => error,
            Ok(disk) => {
                let disk = disk.unwrap();
                let anchor = SortKey::of(&index.get("row-0000").unwrap());
                disk.read_piece(Some(&anchor), ReadSide::After, true, 5, PAGE_BYTES).err().unwrap()
            }
        };
        assert!(is_fatal_snapshot_read(&error), "{fault}: {error}");
    }
}

#[test]
fn undecodable_payload_with_valid_crc_is_an_absent_complete_frame() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("payload.snap");
    write_rows(&path, 3);
    let mut bytes = fs::read(&path).unwrap();
    let start = super::HEADER_BYTES;
    let body_len =
        u32::from_le_bytes(bytes.get(start..start + 4).unwrap().try_into().unwrap()) as usize;
    // Unknown record kind, with a repaired checksum: this exercises decode
    // failure separately from CRC failure while retaining both frame lengths.
    *bytes.get_mut(start + 8).unwrap() = u8::MAX;
    let crc = crc32fast::hash(bytes.get(start + 8..start + 8 + body_len).unwrap());
    bytes.get_mut(start + 4..start + 8).unwrap().copy_from_slice(&crc.to_le_bytes());
    fs::write(&path, bytes).unwrap();
    let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
    let page = snapshot.first_rows(3, PAGE_BYTES).unwrap();
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["row-0001", "row-0002"]
    );
}

#[test]
fn damaged_around_anchor_uses_the_first_sound_ordinal() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("around-damage.snap");
    let index = write_rows(&path, 3);
    damage_frame(&path, 0);
    let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
    let anchor = SortKey::of(&index.get("row-0000").unwrap());
    let page = snapshot.read_piece(Some(&anchor), ReadSide::Around, true, 2, PAGE_BYTES).unwrap();
    assert_eq!(page.first_ordinal, 1);
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["row-0001", "row-0002"]
    );
    assert!(!page.has_after);
}
