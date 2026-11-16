//! Bounded optional kin reads. Failure receipts include every attempted byte;
//! the index decides whether the remaining request budget permits its fallback.
use super::kin_table::lookup::{Cursor, Failure};
use super::{DiskSnapshot, PAGE_BYTES, Position};
use crate::index::{RowKey, SortKey, Summary};
use std::sync::Arc;

#[derive(Clone, Copy, Debug, Default)]
pub(in crate::index) struct KinIo {
    pub bytes: usize,
    pub directory_pages: usize,
    pub search_pages: usize,
    pub walk_pages: usize,
    pub frames: usize,
}

pub(in crate::index) struct KinRequest<'a> {
    pub root: &'a RowKey,
    pub cold_before: u64,
    pub after: Option<&'a SortKey>,
    pub limit: usize,
    pub physical_bytes: usize,
    pub position: Option<Position>,
}

pub(in crate::index) struct KinRow {
    pub row: Arc<Summary>,
    pub depth: u8,
}

pub(in crate::index) struct KinPiece {
    pub rows: Vec<KinRow>,
    pub has_before: bool,
    pub has_after: bool,
    pub closure: bool,
}

pub(in crate::index) enum KinResult<T> {
    Ready(T),
    Unavailable,
    BudgetExhausted,
}

pub(in crate::index) struct KinRead<T> {
    pub result: KinResult<T>,
    pub io: KinIo,
    pub position: Option<Position>,
}

impl<T> KinRead<T> {
    fn unavailable(position: Option<Position>) -> Self {
        Self {
            result: KinResult::Unavailable,
            io: KinIo {
                bytes: position.map_or(0, |position| position.bytes_read),
                ..KinIo::default()
            },
            position,
        }
    }
}

impl DiskSnapshot {
    pub(in crate::index) fn read_cold_family(&self, request: KinRequest<'_>) -> KinRead<KinPiece> {
        let Some(table) = self.kin_table.as_ref().filter(|table| table.is_usable()) else {
            return KinRead::unavailable(request.position);
        };
        let mut cursor = Cursor::new(self, table, &request);
        let result = (|| {
            cursor.seek(&request)?;
            let has_before = request.after.is_some() && cursor.has_before()?;
            let mut rows = Vec::new();
            loop {
                let entry = match cursor.next() {
                    Ok(Some(entry)) => entry,
                    Ok(None) => {
                        return Ok(KinPiece { rows, has_before, has_after: false, closure: true });
                    }
                    Err(error) if !rows.is_empty() => {
                        return Ok(verified_prefix(table, rows, has_before, error));
                    }
                    Err(error) => return Err(error),
                };
                if rows.len() >= request.limit.min(400) {
                    return Ok(KinPiece { rows, has_before, has_after: true, closure: true });
                }
                match cursor.row(entry) {
                    Ok(row) => rows.push(KinRow { row, depth: entry.depth }),
                    Err(error) if !rows.is_empty() => {
                        return Ok(verified_prefix(table, rows, has_before, error));
                    }
                    Err(error) => return Err(error),
                }
            }
        })();
        finish(table, cursor.io, result, request.position)
    }

    pub(in crate::index) fn has_cold_family(
        &self,
        root: &RowKey,
        cold_before: u64,
    ) -> KinRead<bool> {
        let Some(table) = self.kin_table.as_ref().filter(|table| table.is_usable()) else {
            return KinRead::unavailable(None);
        };
        let request = KinRequest {
            root,
            cold_before,
            after: None,
            limit: 1,
            physical_bytes: PAGE_BYTES,
            position: None,
        };
        let mut cursor = Cursor::new(self, table, &request);
        let result =
            cursor.seek(&request).and_then(|()| cursor.next().map(|entry| entry.is_some()));
        finish(table, cursor.io, result, None)
    }
}

/// The cursor has examined these rows in order, so their last key is a
/// continuation even if the index's visibility filter later removes them all.
/// A failed next frame/page must not erase that verified progress (decision 389).
fn verified_prefix(
    table: &super::kin_table::Table,
    rows: Vec<KinRow>,
    has_before: bool,
    failure: Failure,
) -> KinPiece {
    if let Failure::Invalid(error) = failure {
        table.disable(&error);
    }
    // Unavailable comes from read_page, which already disables/counts/logs
    // once. Budget exhaustion keeps the table usable. Neither is retried here.
    KinPiece { rows, has_before, has_after: true, closure: false }
}

fn finish<T>(
    table: &super::kin_table::Table,
    io: KinIo,
    result: Result<T, Failure>,
    position: Option<Position>,
) -> KinRead<T> {
    let result = match result {
        Ok(value) => {
            #[cfg(test)]
            super::record_kin_served();
            KinResult::Ready(value)
        }
        Err(Failure::Budget) => KinResult::BudgetExhausted,
        Err(Failure::Unavailable) => KinResult::Unavailable,
        Err(Failure::Invalid(error)) => {
            table.disable(&error);
            KinResult::Unavailable
        }
    };
    KinRead { result, io, position }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::snapshot::{SortedSnapshot, StreamGeneration};
    use std::fs::OpenOptions;
    use std::io::{Read, Seek, SeekFrom, Write};

    fn fixture(count: usize) -> (tempfile::TempDir, Arc<DiskSnapshot>, RowKey) {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("index.snap");
        let table_path = directory.path().join("index.snap.kin");
        let root = RowKey::new("local", "root");
        let rows = (0..count).map(|index| {
            let mut row = Summary::new(format!("row-{index:05}"));
            row.last_activity = 1;
            row.state = "closed".to_owned();
            row.parent = Some(root.clone());
            Ok(Arc::new(row))
        });
        SortedSnapshot::write_stream_generation_with_table(StreamGeneration {
            path: &path,
            seq: 1,
            log_offset: 0,
            log_name: None,
            covered_generation: 0,
            meta: Default::default(),
            rows,
            table_path: Some(&table_path),
        })
        .unwrap();
        let disk = DiskSnapshot::open(path).unwrap().unwrap();
        (directory, disk, root)
    }

    fn request<'a>(
        disk: &DiskSnapshot,
        root: &'a RowKey,
        after: Option<&'a SortKey>,
    ) -> KinRequest<'a> {
        KinRequest {
            root,
            cold_before: 2,
            after,
            limit: 10,
            physical_bytes: PAGE_BYTES,
            position: after.map(|key| disk.seek_position(key, false).unwrap()),
        }
    }

    fn rewrite_page(directory: &tempfile::TempDir, page: u64, edit: impl FnOnce(&mut [u8; 4096])) {
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(directory.path().join("index.snap.kin"))
            .unwrap();
        file.seek(SeekFrom::Start((page + 1) * 4096)).unwrap();
        let mut bytes = [0; 4096];
        file.read_exact(&mut bytes).unwrap();
        edit(&mut bytes);
        let crc = crc32fast::hash(&bytes[..4092]);
        bytes[4092..].copy_from_slice(&crc.to_le_bytes());
        file.seek(SeekFrom::Start((page + 1) * 4096)).unwrap();
        file.write_all(&bytes).unwrap();
        file.sync_all().unwrap();
    }

    #[test]
    fn cold_kin_empty_table_needs_no_pages() {
        let (_directory, disk, root) = fixture(0);
        let answer = disk.has_cold_family(&root, 2);
        assert!(matches!(answer.result, KinResult::Ready(false)));
        assert_eq!(answer.io.bytes, 0);
    }

    #[test]
    fn cold_kin_equal_activity_cursor_seeks_without_scanning_the_tie() {
        let (_directory, disk, root) = fixture(11_000);
        let cursor = SortKey { last_activity: 1, row: RowKey::new("local", "row-10989") };
        let before = super::super::read_probe();
        let answer = disk.read_cold_family(request(&disk, &root, Some(&cursor)));
        let KinResult::Ready(piece) = answer.result else { panic!("table cursor failed") };
        let ids: Vec<_> = piece.rows.iter().map(|row| row.row.chat_id.clone()).collect();
        assert_eq!(
            ids,
            (10_990..11_000).map(|index| format!("row-{index:05}")).collect::<Vec<_>>()
        );
        assert!(!piece.has_after);
        assert!(piece.has_before);
        assert_eq!(answer.io.frames, 10, "placement reads no candidate frame");
        assert_eq!(answer.io.bytes, super::super::read_probe().0 - before.0);
        assert!(answer.io.bytes <= PAGE_BYTES);
        assert_eq!(answer.io.directory_pages, 1);
        assert!(answer.io.search_pages <= 8); // ceil(log2(ceil(11_000/127))) + 1
    }

    #[test]
    fn cold_kin_unavailable_table_preserves_position_and_charged_seek() {
        for disabled in [false, true] {
            let (_directory, disk, root) = fixture(20);
            let mut disk = Arc::try_unwrap(disk).unwrap();
            if disabled {
                disk.kin_table.as_ref().unwrap().disable(&std::io::Error::other("test"));
            } else {
                disk.kin_table = None;
            }
            let anchor = SortKey { last_activity: 1, row: RowKey::new("local", "row-00005") };
            let before = super::super::read_probe();
            let answer = disk.read_cold_family(request(&disk, &root, Some(&anchor)));
            assert!(matches!(answer.result, KinResult::Unavailable));
            let position = answer.position.expect("fallback must not restart at the first row");
            assert!(position.bytes_read > 0);
            assert_eq!(answer.io.bytes, position.bytes_read);
            let page = disk
                .read_piece_from_position(
                    position,
                    crate::index::ReadSide::After,
                    1,
                    PAGE_BYTES - answer.io.bytes,
                    answer.io.bytes,
                )
                .unwrap();
            assert_eq!(page.rows.first().unwrap().chat_id, "row-00006");
            assert_eq!(page.bytes_read, super::super::read_probe().0 - before.0);
            assert!(page.bytes_read <= PAGE_BYTES);
        }
    }

    #[test]
    fn cold_kin_budget_exhaustion_keeps_the_table_usable() {
        let (_directory, disk, root) = fixture(1);
        let mut ask = request(&disk, &root, None);
        ask.physical_bytes = 8192;
        let answer = disk.read_cold_family(ask);
        assert!(matches!(answer.result, KinResult::BudgetExhausted));
        assert_eq!(answer.io.bytes, 8192);
        assert!(disk.has_kin_table());
        assert!(matches!(
            disk.read_cold_family(request(&disk, &root, None)).result,
            KinResult::Ready(_)
        ));
    }

    #[test]
    fn cold_kin_crc_valid_bad_slot_is_set_aside() {
        let (directory, disk, root) = fixture(1);
        rewrite_page(&directory, 0, |page| page[..4].copy_from_slice(&u32::MAX.to_le_bytes()));
        let answer = disk.read_cold_family(request(&disk, &root, None));
        assert!(matches!(answer.result, KinResult::Unavailable));
        assert_eq!(answer.io.bytes, 4096);
        assert!(!disk.has_kin_table());
        assert_eq!(disk.read_cold_family(request(&disk, &root, None)).io.bytes, 0);
    }

    #[test]
    fn cold_kin_crc_valid_bad_entry_is_set_aside() {
        for (byte, value) in [(30, 0), (30, 65), (31, 0), (31, 3), (31, 2)] {
            let (directory, disk, root) = fixture(1);
            rewrite_page(&directory, 1, |page| page[byte] = value);
            let answer = disk.read_cold_family(request(&disk, &root, None));
            assert!(matches!(answer.result, KinResult::Unavailable));
            assert_eq!(answer.io.bytes, 8192);
            assert!(!disk.has_kin_table());
        }
    }

    #[test]
    fn cold_kin_crc_valid_mismatched_check_is_set_aside() {
        let (directory, disk, root) = fixture(1);
        rewrite_page(&directory, 1, |page| page[24] ^= 1);
        let answer = disk.has_cold_family(&root, 2);
        assert!(matches!(answer.result, KinResult::Unavailable));
        assert_eq!(answer.io.bytes, 8192);
        assert!(!disk.has_kin_table());
    }

    #[test]
    fn cold_kin_crc_valid_out_of_extent_frame_is_set_aside() {
        for offset in [0, u64::MAX] {
            let (directory, disk, root) = fixture(1);
            rewrite_page(&directory, 1, |page| page[16..24].copy_from_slice(&offset.to_le_bytes()));
            let answer = disk.read_cold_family(request(&disk, &root, None));
            assert!(matches!(answer.result, KinResult::Unavailable));
            assert_eq!(answer.io.frames, 0);
            assert!(!disk.has_kin_table());
        }
    }

    #[test]
    fn cold_kin_damaged_frame_retains_the_verified_prefix() {
        let (directory, disk, root) = fixture(2);
        let entry_page = disk.kin_table.as_ref().unwrap().read_page(1).unwrap();
        let offset = u64::from_le_bytes(entry_page[48..56].try_into().unwrap());
        let mut file =
            OpenOptions::new().write(true).open(directory.path().join("index.snap")).unwrap();
        file.seek(SeekFrom::Start(offset + 8)).unwrap();
        file.write_all(&[255]).unwrap();
        file.sync_all().unwrap();
        let answer = disk.read_cold_family(request(&disk, &root, None));
        let KinResult::Ready(piece) = answer.result else { panic!("verified prefix lost") };
        assert_eq!(piece.rows.len(), 1);
        assert_eq!(piece.rows[0].row.chat_id, "row-00000");
        assert!(piece.has_after);
        assert!(!piece.has_before);
        assert_eq!(answer.io.frames, 2);
        assert!(!disk.has_kin_table());
        let next = SortKey::of(&piece.rows[0].row);
        let retry = disk.read_cold_family(request(&disk, &root, Some(&next)));
        assert!(matches!(retry.result, KinResult::Unavailable));
        assert_eq!(retry.io.bytes, retry.position.unwrap().bytes_read);
    }

    #[test]
    fn cold_kin_later_page_checksum_failure_retains_the_verified_prefix() {
        let (directory, disk, root) = fixture(381);
        // Three pages: placement visits pages 1 then 0. Page 2 is first read
        // only after the first 254 rows have been examined successfully.
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(directory.path().join("index.snap.kin"))
            .unwrap();
        let offset = 4 * 4096; // header, directory, then entry pages 0 and 1
        file.seek(SeekFrom::Start(offset)).unwrap();
        let mut byte = [0];
        file.read_exact(&mut byte).unwrap();
        byte[0] ^= 1;
        file.seek(SeekFrom::Start(offset)).unwrap();
        file.write_all(&byte).unwrap();
        file.sync_all().unwrap();
        let mut ask = request(&disk, &root, None);
        ask.limit = 400;
        let answer = disk.read_cold_family(ask);
        let KinResult::Ready(piece) = answer.result else { panic!("verified prefix lost") };
        assert_eq!(piece.rows.len(), 254);
        assert_eq!(piece.rows[253].row.chat_id, "row-00253");
        assert!(piece.has_after);
        assert_eq!(answer.io.frames, 254);
        assert!(answer.io.bytes <= PAGE_BYTES);
        assert!(!disk.has_kin_table());
        let next = SortKey::of(&piece.rows[253].row);
        let retry = disk.read_cold_family(request(&disk, &root, Some(&next)));
        assert!(matches!(retry.result, KinResult::Unavailable));
        assert_eq!(retry.io.bytes, retry.position.unwrap().bytes_read);
    }
}
