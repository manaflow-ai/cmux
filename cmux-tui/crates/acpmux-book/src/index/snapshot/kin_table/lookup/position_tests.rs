//! Sparse physical files exercise the largest search without allocating its
//! logical terabyte snapshot or 8-GiB table. Only the search path is populated;
//! every byte the request actually reads comes through the real file wrapper.
use super::*;
use crate::index::snapshot::{
    CHECKPOINT_BYTES, Checkpoint, Head, Position, SEEK_BYTES, read_probe,
};
use crate::index::{IndexRecord, ReadSide, RowKey, SortKey, codec};
use std::fs::{File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::sync::atomic::AtomicBool;

const BUCKET_PAGES: u64 = 1 << 21;
const CHECKPOINTS: usize = 1 << 24;
const FRAME_BYTES: usize = 512;
const ROWS_PER_BLOCK: u64 = (SEEK_BYTES / FRAME_BYTES) as u64;

fn write_at(file: &mut File, offset: u64, bytes: &[u8]) {
    file.seek(SeekFrom::Start(offset)).unwrap();
    file.write_all(bytes).unwrap();
}

fn seal(page: &mut [u8; PAGE_BYTES]) {
    let (body, tail) = page.split_at_mut(PAGE_BYTES - 4);
    tail.copy_from_slice(&crc32fast::hash(body).to_le_bytes());
}

fn key(ordinal: u64) -> RowKey {
    RowKey::new("local", format!("row-{ordinal:010}"))
}

fn sparse_snapshot(path: &std::path::Path, root: &RowKey) -> DiskSnapshot {
    let mut file = OpenOptions::new().create_new(true).read(true).write(true).open(path).unwrap();
    let data_end = HEADER_BYTES as u64 + CHECKPOINTS as u64 * SEEK_BYTES as u64;
    let directory_bytes = CHECKPOINTS * CHECKPOINT_BYTES;
    file.set_len(data_end + directory_bytes as u64).unwrap();
    let mut block = Vec::with_capacity(SEEK_BYTES);
    for ordinal in 0..ROWS_PER_BLOCK {
        let mut row = Summary::new(key(ordinal).chat_id.to_string());
        row.last_activity = 1;
        row.state = "closed".to_owned();
        row.parent = Some(root.clone());
        let mut record = IndexRecord {
            seq: 1,
            origin: row.origin.clone(),
            chat_id: row.chat_id.clone(),
            summary: row,
            gone: false,
        };
        // Plain ASCII extends the encoded record by exactly this many bytes.
        record.summary.title =
            "x".repeat(FRAME_BYTES - TRAILER_BYTES - codec::encode(&record).unwrap().len());
        let encoded = codec::encode(&record).unwrap();
        assert_eq!(encoded.len() + TRAILER_BYTES, FRAME_BYTES);
        block.extend_from_slice(&encoded);
        block.extend_from_slice(&(encoded.len() as u32).to_le_bytes());
    }
    assert_eq!(block.len(), SEEK_BYTES);
    write_at(&mut file, HEADER_BYTES as u64, &block);
    // Querying the first key visits the last checkpoint, then repeatedly the
    // lower half, and finally the next checkpoint to bound the first block.
    let mut checkpoint_indexes = vec![CHECKPOINTS - 1, 0, 1];
    let mut right = CHECKPOINTS - 1;
    while right > 0 {
        let middle = right / 2;
        checkpoint_indexes.push(middle);
        right = middle;
    }
    checkpoint_indexes.sort_unstable();
    checkpoint_indexes.dedup();
    for index in checkpoint_indexes {
        let ordinal = index as u64 * ROWS_PER_BLOCK;
        let checkpoint = Checkpoint {
            key: SortKey { last_activity: 1, row: key(ordinal) },
            offset: HEADER_BYTES as u64 + index as u64 * SEEK_BYTES as u64,
            ordinal,
            first_len: FRAME_BYTES,
        };
        write_at(
            &mut file,
            data_end + (index * CHECKPOINT_BYTES) as u64,
            &checkpoint.encode().unwrap(),
        );
    }
    DiskSnapshot {
        file,
        head: Head {
            seq: 1,
            log_offset: 0,
            log_name: None,
            covered_generation: 0,
            data_end,
            directory_bytes,
            count: CHECKPOINTS as u64 * ROWS_PER_BLOCK,
            first_lengths: vec![FRAME_BYTES as u16; 400],
            origins_offset: 0,
            origins_bytes: 0,
        },
        origins: Vec::new(),
        marks: Vec::new(),
        kin_table: None,
    }
}

fn sparse_table(path: &std::path::Path, root: &RowKey) -> Table {
    let entries = BUCKET_PAGES * ENTRIES_PER_PAGE as u64;
    let slots = entries.div_ceil(64).next_power_of_two() as u32;
    let directory_pages = slots.div_ceil(SLOTS_PER_PAGE as u32);
    let mut file = OpenOptions::new().create_new(true).read(true).write(true).open(path).unwrap();
    file.set_len((1 + u64::from(directory_pages) + BUCKET_PAGES) * PAGE_BYTES as u64).unwrap();
    let fingerprint = key_fingerprint(root, FAMILY_KIND);
    let slot = slot_for(fingerprint.0, slots) as usize;
    let mut directory = [0u8; PAGE_BYTES];
    let at = (slot % SLOTS_PER_PAGE) * 8;
    directory.get_mut(at + 4..at + 8).unwrap().copy_from_slice(&(entries as u32).to_le_bytes());
    seal(&mut directory);
    write_at(&mut file, (1 + slot / SLOTS_PER_PAGE) as u64 * PAGE_BYTES as u64, &directory);
    let mut page_index = BUCKET_PAGES / 2;
    loop {
        let mut page = [0u8; PAGE_BYTES];
        for (within, bytes) in page.chunks_exact_mut(ENTRY_BYTES).take(ENTRIES_PER_PAGE).enumerate()
        {
            let ordinal = page_index * ENTRIES_PER_PAGE as u64 + within as u64;
            Entry {
                hash: fingerprint.0,
                activity: 1,
                offset: HEADER_BYTES as u64 + ordinal * FRAME_BYTES as u64,
                check: fingerprint.1,
                len: FRAME_BYTES as u16,
                depth: 1,
                kind: FAMILY_KIND,
            }
            .encode(bytes)
            .unwrap();
        }
        seal(&mut page);
        if page_index == 0 {
            // Last search page: corruption happens after every other placement
            // read, before a single candidate frame has been examined.
            *page.first_mut().unwrap() ^= 1;
        }
        write_at(
            &mut file,
            (1 + u64::from(directory_pages) + page_index) * PAGE_BYTES as u64,
            &page,
        );
        if page_index == 0 {
            break;
        }
        page_index /= 2;
    }
    Table {
        file,
        header: super::super::TableHeader {
            entries,
            slots,
            directory_pages,
            packed_entries: entries,
        },
        disabled: AtomicBool::new(false),
    }
}

#[test]
fn cold_kin_worst_bucket_placement_failure_pays_seek_once_and_pager_progresses() {
    let directory = tempfile::tempdir().unwrap();
    let root = RowKey::new("local", "root");
    let mut disk = sparse_snapshot(&directory.path().join("index.snap"), &root);
    disk.kin_table = Some(sparse_table(&directory.path().join("index.snap.kin"), &root));
    let anchor = SortKey { last_activity: 1, row: key(0) };
    let before = read_probe();
    let position = disk.seek_position(&anchor, true).unwrap();
    assert_eq!(position.offset, HEADER_BYTES as u64);
    assert!(position.bytes_read <= 80_032);
    assert!(position.bytes_read >= SEEK_BYTES + 24 * CHECKPOINT_BYTES);
    let ask = KinRequest {
        root: &root,
        cold_before: 2,
        after: Some(&anchor),
        limit: 400,
        physical_bytes: super::super::super::PAGE_BYTES,
        position: Some(position),
    };
    let answer = disk.read_cold_family(ask);
    assert!(matches!(answer.result, crate::index::snapshot::kin_read::KinResult::Unavailable));
    assert_eq!(answer.io.frames, 0);
    assert_eq!(answer.io.directory_pages, 1);
    assert_eq!(answer.io.search_pages, 22);
    assert_eq!(answer.io.bytes, position.bytes_read + 23 * PAGE_BYTES);
    assert_eq!(read_probe().0 - before.0, answer.io.bytes);
    assert!(!disk.has_kin_table());
    let remaining = super::super::super::PAGE_BYTES - answer.io.bytes;
    assert!(remaining >= 87_904);
    assert!(remaining >= crate::index::MAX_INDEX_RECORD_BYTES + TRAILER_BYTES);
    let Position { offset, .. } = answer.position.unwrap();
    assert_eq!(offset, position.offset);
    let page = disk
        .read_piece_from_position(
            answer.position.unwrap(),
            ReadSide::After,
            1,
            remaining,
            answer.io.bytes,
        )
        .unwrap();
    assert_eq!(page.rows.len(), 1);
    assert_eq!(page.rows.first().unwrap().key(), key(0));
    assert_eq!(page.bytes_read, read_probe().0 - before.0);
    assert!(page.bytes_read <= super::super::super::PAGE_BYTES);
    assert_eq!(read_probe().2 - before.2, 1);
}
