use super::{
    CHECKPOINT_BYTES, Checkpoint, DiskSnapshot, FIRST_ROWS, HEADER_BYTES, Head, MAGIC, PAGE_BYTES,
    SEEK_BYTES, TRAILER_BYTES,
};
use crate::index::{IndexRecord, SortKey, Summary, SummaryIndex, codec};
use std::fs::{self, File};
use std::io::{self, BufWriter, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::Arc;

pub struct SortedSnapshot;

impl SortedSnapshot {
    pub const VERSION: u32 = 3;

    pub fn write(path: impl AsRef<Path>, index: &SummaryIndex) -> io::Result<()> {
        Self::write_with_offset(path, index, 0)
    }

    pub fn write_with_offset(
        path: impl AsRef<Path>,
        index: &SummaryIndex,
        log_offset: u64,
    ) -> io::Result<()> {
        Self::write_with_offset_and_name(path, index, log_offset, None)
    }

    pub(in crate::index) fn write_with_offset_and_name(
        path: impl AsRef<Path>,
        index: &SummaryIndex,
        log_offset: u64,
        log_name: Option<&str>,
    ) -> io::Result<()> {
        Self::write_stream_generation(
            path,
            index.seq(),
            log_offset,
            log_name,
            0,
            index.merged_rows(),
        )
    }

    /// The input is ordered. Records and fixed-size sparse entries go to bounded
    /// buffered streams; only the previous key and first 400 lengths are kept.
    pub fn write_stream(
        path: impl AsRef<Path>,
        seq: u64,
        log_offset: u64,
        log_name: Option<&str>,
        rows: impl IntoIterator<Item = io::Result<Arc<Summary>>>,
    ) -> io::Result<()> {
        Self::write_stream_generation(path, seq, log_offset, log_name, 0, rows)
    }

    pub fn write_stream_generation(
        path: impl AsRef<Path>,
        seq: u64,
        log_offset: u64,
        log_name: Option<&str>,
        covered_generation: u64,
        rows: impl IntoIterator<Item = io::Result<Arc<Summary>>>,
    ) -> io::Result<()> {
        let path = path.as_ref();
        let mut temp_name = path.as_os_str().to_os_string();
        temp_name.push(".new");
        let temp = std::path::PathBuf::from(temp_name);
        let mut directory_name = path.as_os_str().to_os_string();
        directory_name.push(".directory.new");
        let directory_path = std::path::PathBuf::from(directory_name);
        let mut writer = BufWriter::new(File::create(&temp)?);
        let mut directory = BufWriter::new(File::create(&directory_path)?);
        writer.write_all(&[0; HEADER_BYTES])?;
        let mut offset = HEADER_BYTES as u64;
        let mut count = 0;
        let mut directory_bytes = 0;
        let mut last_checkpoint: Option<(u64, u64)> = None;
        let mut previous = None;
        let mut last_key = None;
        let mut last_len = 0;
        let mut first_lengths = Vec::new();
        for row in rows {
            let row = row?;
            let key = SortKey::of(&row);
            if previous.as_ref().is_some_and(|previous| previous >= &key) {
                return Err(codec::invalid("unsorted snapshot input"));
            }
            let record = IndexRecord {
                seq,
                origin: row.origin.clone(),
                chat_id: row.chat_id.clone(),
                summary: row.as_ref().clone(),
                gone: false,
            };
            let bytes = codec::encode(&record)?;
            let len = bytes.len() + TRAILER_BYTES;
            if last_checkpoint.is_none_or(|(start, ordinal)| {
                count - ordinal == 256 || offset + len as u64 - start > SEEK_BYTES as u64
            }) {
                let checkpoint =
                    Checkpoint { key: key.clone(), offset, ordinal: count, first_len: len };
                directory.write_all(&checkpoint.encode()?)?;
                directory_bytes += CHECKPOINT_BYTES;
                last_checkpoint = Some((offset, count));
            }
            if first_lengths.len() < FIRST_ROWS {
                first_lengths.push(u16::try_from(len).map_err(io::Error::other)?);
            }
            writer.write_all(&bytes)?;
            writer.write_all(&(bytes.len() as u32).to_le_bytes())?;
            offset += len as u64;
            count += 1;
            last_key = Some(key.clone());
            last_len = len;
            previous = Some(key);
        }
        directory.flush()?;
        drop(directory);
        let mut directory_file = File::open(&directory_path)?;
        let copied = io::copy(&mut directory_file, &mut writer)?;
        if copied != directory_bytes as u64 {
            return Err(codec::invalid("snapshot directory copy"));
        }
        drop(directory_file);
        fs::remove_file(&directory_path)?;
        let head = Head {
            seq,
            log_offset,
            log_name: log_name.map(str::to_owned),
            covered_generation,
            data_end: offset,
            directory_bytes,
            count,
            last_key,
            last_len,
            first_lengths,
        };
        let json = serde_json::to_vec(&head).map_err(io::Error::other)?;
        if json.len() > HEADER_BYTES - 16 {
            return Err(codec::invalid("snapshot head too large"));
        }
        let mut header = Vec::from(MAGIC.as_slice());
        header.extend_from_slice(&(json.len() as u32).to_le_bytes());
        header.extend_from_slice(&json);
        header.resize(HEADER_BYTES - 4, 0);
        header.extend_from_slice(&crc32fast::hash(&header).to_le_bytes());
        writer.seek(SeekFrom::Start(0))?;
        writer.write_all(&header)?;
        writer.flush()?;
        writer.get_ref().sync_all()?;
        fs::rename(&temp, path)?;
        File::open(path.parent().unwrap_or_else(|| Path::new(".")))?.sync_all()?;
        Ok(())
    }

    /// Explicit full materialization for tools/tests, never used by the opener.
    pub fn read(path: impl AsRef<Path>) -> io::Result<Option<SummaryIndex>> {
        Ok(Self::read_with_offset(path)?.map(|(index, _)| index))
    }

    pub fn read_with_offset(path: impl AsRef<Path>) -> io::Result<Option<(SummaryIndex, u64)>> {
        let Some(snapshot) = DiskSnapshot::open(path)? else {
            return Ok(None);
        };
        let mut index = SummaryIndex::new();
        index.seq = snapshot.seq();
        let mut offset = HEADER_BYTES as u64;
        let mut ordinal = 0;
        while offset < snapshot.head.data_end {
            let piece = snapshot.piece(offset, ordinal, PAGE_BYTES)?;
            if piece.rows.is_empty() {
                return Err(codec::invalid("snapshot made no progress"));
            }
            ordinal += piece.rows.len() as u64;
            for row in piece.rows {
                index = index.apply(snapshot.seq(), row.as_ref().clone());
            }
            offset = piece.next_offset;
        }
        Ok(Some((index, snapshot.head.log_offset)))
    }
}
