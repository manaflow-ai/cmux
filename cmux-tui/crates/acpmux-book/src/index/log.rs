//! CRC-framed bounded log records and recoverable generation changes.
use super::compaction::{Compaction, cleanup_stages};
use super::{DiskSnapshot, IndexRecord, OriginRecord, RowKey, Summary, SummaryIndex, codec};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

pub struct IndexLog {
    file: File,
    path: PathBuf,
    next_seq: u64,
    offset: u64,
    oldest_seq: u64,
    generation: u64,
    closed_bytes: u64,
}

impl IndexLog {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let requested = path.as_ref();
        let snapshot = DiskSnapshot::open(requested.with_extension("snap"))?;
        Self::open_with_snapshot(requested, snapshot.as_deref())
    }

    /// The service opener supplies the already-read head, so startup observes
    /// one snapshot generation and does not read its head twice.
    pub fn open_with_snapshot(
        requested: impl AsRef<Path>,
        snapshot: Option<&DiskSnapshot>,
    ) -> io::Result<Self> {
        let requested = requested.as_ref();
        let parent = requested.parent().unwrap_or_else(|| Path::new("."));
        let mut cleaned = cleanup_stages(parent)?;
        let covered = snapshot.map_or(0, DiskSnapshot::covered_generation);
        let mut seq = snapshot.map_or(0, DiskSnapshot::seq);
        let mut generations = generation_paths(requested)?;
        generations.sort_by_key(|(generation, _)| *generation);
        let mut active = None;
        let mut retained_bytes = 0;
        let mut oldest = None;
        let mut previous_generation = None;
        for (generation, path) in generations {
            if previous_generation == Some(generation) {
                return Err(codec::invalid("duplicate log generation"));
            }
            previous_generation = Some(generation);
            if generation <= covered {
                fs::remove_file(path)?;
                cleaned = true;
                continue;
            }
            let offset = if generation == 1 && covered == 0 {
                snapshot.map_or(0, DiskSnapshot::log_offset)
            } else {
                0
            };
            let log = Self::open_tail(path, seq, offset, generation)?;
            if oldest.is_none() && log.offset > offset {
                oldest = Some(log.oldest_seq);
            }
            seq = log.next_seq;
            retained_bytes += log.offset;
            active = Some(log);
        }
        if cleaned {
            File::open(parent)?.sync_all()?;
        }
        let mut log = match active {
            Some(log) => log,
            None => {
                let generation = covered
                    .checked_add(1)
                    .ok_or_else(|| codec::invalid("log generation exhausted"))?;
                let path = if generation == 1 {
                    requested.to_owned()
                } else {
                    parent.join(format!("index.log.{generation}"))
                };
                Self::open_tail(path, seq, 0, generation)?
            }
        };
        log.oldest_seq = oldest.unwrap_or_else(|| seq.saturating_add(1));
        log.closed_bytes = retained_bytes.saturating_sub(log.offset);
        Ok(log)
    }

    pub(super) fn open_tail(
        path: PathBuf,
        seq: u64,
        covered: u64,
        generation: u64,
    ) -> io::Result<Self> {
        let mut file =
            OpenOptions::new().create(true).truncate(false).read(true).write(true).open(&path)?;
        if file.metadata()?.len() < covered {
            return Err(codec::invalid("log shorter than snapshot offset"));
        }
        let mut reader = BufReader::new(file.try_clone()?);
        reader.seek(SeekFrom::Start(covered))?;
        let mut offset = covered;
        let mut next_seq = seq;
        let mut previous_seq = 0;
        let mut oldest_seq = seq.saturating_add(1);
        loop {
            match codec::read_any(&mut reader) {
                Ok(Some((record, len))) if record_seq(&record) > previous_seq => {
                    if offset == covered {
                        oldest_seq = record_seq(&record);
                    }
                    offset += len as u64;
                    previous_seq = record_seq(&record);
                    next_seq = next_seq.max(record_seq(&record));
                }
                Ok(None) => break,
                Ok(Some(_)) => break,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::UnexpectedEof | io::ErrorKind::InvalidData
                    ) =>
                {
                    // A short final frame is the existing torn-tail repair.
                    // Once the complete frame boundary is present, however,
                    // a bad length, checksum or payload means the next log
                    // boundary is unknown and the hub must rebuild from its
                    // sources instead of silently cutting history.
                    if complete_frame_at(&file, offset)? {
                        return Err(error);
                    }
                    break;
                }
                Err(error) => return Err(error),
            }
        }
        if offset != file.metadata()?.len() {
            file.set_len(offset)?;
            file.sync_data()?;
        }
        file.seek(SeekFrom::Start(offset))?;
        Ok(Self { file, path, next_seq, offset, oldest_seq, generation, closed_bytes: 0 })
    }

    pub fn append(&mut self, summary: Summary) -> io::Result<IndexRecord> {
        let summary = summary.prepare()?;
        let record = IndexRecord {
            seq: self.next_seq.saturating_add(1),
            origin: summary.origin.clone(),
            chat_id: summary.chat_id.clone(),
            summary,
            gone: false,
        };
        self.append_record(&record)?;
        Ok(record)
    }

    pub fn append_remove(&mut self, chat_id: impl Into<String>) -> io::Result<IndexRecord> {
        self.append_gone(&RowKey::new("local", chat_id.into()))
    }

    pub fn append_gone(&mut self, key: &RowKey) -> io::Result<IndexRecord> {
        key.validate()?;
        let record = IndexRecord {
            seq: self.next_seq.saturating_add(1),
            origin: key.origin.to_string(),
            chat_id: key.chat_id.to_string(),
            summary: Summary::new(key.chat_id.to_string()),
            gone: true,
        };
        self.append_record(&record)?;
        Ok(record)
    }

    pub fn append_record(&mut self, record: &IndexRecord) -> io::Result<()> {
        if record.seq <= self.next_seq {
            return Err(codec::invalid("nonmonotonic log append"));
        }
        let bytes = codec::encode(record)?;
        // A failed partial write is cut before another record may be appended.
        self.file.set_len(self.offset)?;
        self.file.seek(SeekFrom::Start(self.offset))?;
        self.file.write_all(&bytes)?;
        self.offset += bytes.len() as u64;
        self.next_seq = record.seq;
        Ok(())
    }

    pub fn append_origin(&mut self, record: &OriginRecord) -> io::Result<u64> {
        let seq = record.seq;
        if seq <= self.next_seq {
            return Err(codec::invalid("nonmonotonic origin append"));
        }
        let bytes = codec::encode_origin(seq, record)?;
        self.file.set_len(self.offset)?;
        self.file.seek(SeekFrom::Start(self.offset))?;
        self.file.write_all(&bytes)?;
        self.offset += bytes.len() as u64;
        self.next_seq = seq;
        Ok(seq)
    }

    pub fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
    pub fn sync(&mut self) -> io::Result<()> {
        self.file.sync_data()
    }
    pub fn next_seq(&self) -> u64 {
        self.next_seq
    }
    pub fn oldest_seq(&self) -> u64 {
        self.oldest_seq
    }
    pub fn offset(&self) -> u64 {
        self.offset
    }
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn active_path(&self) -> &Path {
        &self.path
    }
    pub fn retained_bytes(&self) -> u64 {
        self.closed_bytes.saturating_add(self.offset)
    }
    /// Rotate the active generation in O(1), leaving the old generation for
    /// the snapshot worker to read. The new file receives all future appends.
    pub fn rotate(&mut self, snapshot_seq: u64) -> io::Result<Compaction> {
        if snapshot_seq != self.next_seq {
            return Err(codec::invalid("rotation sequence is not current"));
        }
        self.sync()?;
        let parent = self.path.parent().unwrap_or_else(|| Path::new(".")).to_owned();
        // A failed snapshot leaves the active generation empty. Retrying it
        // must not manufacture another log; the same closed generations are
        // still the complete input for this captured sequence. This also
        // retries a failed sync after creation of the active generation.
        if self.offset == 0 {
            self.file.sync_all()?;
            File::open(&parent)?.sync_all()?;
            return Ok(Compaction::new(parent, self.generation.saturating_sub(1), snapshot_seq));
        }
        let closed_generation = self.generation;
        if closed_generation == 1
            && self.path.file_name() == Some(std::ffi::OsStr::new("index.log"))
        {
            let closed = parent.join("index.log.1");
            if closed.exists() {
                return Err(codec::invalid("duplicate initial generation"));
            }
            fs::rename(&self.path, &closed)?;
            self.path = closed;
        }
        let next_generation = closed_generation
            .checked_add(1)
            .ok_or_else(|| codec::invalid("log generation exhausted"))?;
        let active = parent.join(format!("index.log.{next_generation}"));
        let file = OpenOptions::new().create_new(true).read(true).write(true).open(&active)?;
        // Once created, own the new generation even if its sync fails. A
        // retry can sync and reuse it; it must never be wedged behind
        // create_new on an orphan left by a failed cleanup.
        self.closed_bytes = self.closed_bytes.saturating_add(self.offset);
        self.file = file;
        self.path = active;
        self.generation = next_generation;
        self.offset = 0;
        self.file.sync_all()?;
        File::open(&parent)?.sync_all()?;
        // The active generation is empty; retain the old oldest cursor until
        // the snapshot worker commits its covered generation.
        Ok(Compaction::new(parent, closed_generation, snapshot_seq))
    }

    pub fn compact(&mut self, path: impl AsRef<Path>, index: &SummaryIndex) -> io::Result<()> {
        let mut plan = self.rotate(index.seq())?;
        plan.snapshot_path = path.as_ref().to_owned();
        let result = plan.run(std::sync::Arc::new(index.clone()))?;
        if result.cleanup_errors != 0 {
            return Err(io::Error::other(format!(
                "compaction installed but cleanup had {} errors",
                result.cleanup_errors
            )));
        }
        self.compacted(result.covered_generation, result.seq);
        Ok(())
    }

    pub fn compacted(&mut self, covered_generation: u64, seq: u64) {
        self.oldest_seq = seq.saturating_add(1);
        self.closed_bytes = 0;
        debug_assert!(self.generation > covered_generation);
    }
}

/// Whether the bytes beginning at `offset` contain a complete framed record.
/// A declared length beyond the format bound is structural damage even when
/// the file ends before that length, because no safe next boundary exists.
fn complete_frame_at(file: &File, offset: u64) -> io::Result<bool> {
    let total = file.metadata()?.len();
    let remaining = total.saturating_sub(offset);
    if remaining < 8 {
        return Ok(false);
    }
    let mut probe = file.try_clone()?;
    probe.seek(SeekFrom::Start(offset))?;
    let mut header = [0; 8];
    io::Read::read_exact(&mut probe, &mut header)?;
    let length = u32::from_le_bytes(header[..4].try_into().unwrap()) as u64;
    if length > (super::MAX_INDEX_RECORD_BYTES - 8) as u64 {
        return Ok(true);
    }
    Ok(remaining >= 8 + length)
}

pub fn replay_log(path: impl AsRef<Path>, index: SummaryIndex) -> io::Result<SummaryIndex> {
    replay_log_from(path, 0, index)
}

pub fn replay_log_from(
    path: impl AsRef<Path>,
    offset: u64,
    mut index: SummaryIndex,
) -> io::Result<SummaryIndex> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(index),
        Err(error) => return Err(error),
    };
    let mut reader = BufReader::new(file);
    reader.seek(SeekFrom::Start(offset))?;
    while let Some((record, _)) = codec::read_any(&mut reader)? {
        let seq = record_seq(&record);
        if seq <= index.seq() {
            continue;
        }
        match record {
            codec::LogRecord::Origin(origin) => index = index.replay_origin(seq, origin),
            codec::LogRecord::Row(record) if record.gone => {
                index = index
                    .remove_row(seq, &RowKey::new(record.origin, record.chat_id))
                    .unwrap_or(index)
                    .advance_seq(seq);
            }
            codec::LogRecord::Row(record) => index = index.apply_summary(seq, record.summary),
        }
    }
    Ok(index)
}

fn record_seq(record: &codec::LogRecord) -> u64 {
    match record {
        codec::LogRecord::Row(record) => record.seq,
        codec::LogRecord::Origin(record) => record.seq,
    }
}

/// Replays every complete generation newer than the snapshot's covered
/// generation. Directory order is irrelevant; generation numbers are the
/// durable order established by rotation.
pub fn replay_generation_logs(
    directory: impl AsRef<Path>,
    covered_generation: u64,
    mut index: SummaryIndex,
) -> io::Result<SummaryIndex> {
    let requested = directory.as_ref().join("index.log");
    let mut generations = generation_paths(&requested)?;
    generations.sort_by_key(|(generation, _)| *generation);
    for (generation, path) in generations {
        if generation > covered_generation {
            index = replay_log(&path, index)?;
        }
    }
    Ok(index)
}

fn generation_paths(requested: &Path) -> io::Result<Vec<(u64, PathBuf)>> {
    let parent = requested.parent().unwrap_or_else(|| Path::new("."));
    let mut paths = Vec::new();
    if requested.exists() {
        paths.push((1, requested.to_owned()));
    }
    let prefix = requested.file_name().and_then(|name| name.to_str()).unwrap_or("index.log");
    let prefix = format!("{prefix}.");
    for entry in fs::read_dir(parent)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(number) = name.strip_prefix(&prefix) else { continue };
        let Ok(generation) = number.parse::<u64>() else { continue };
        paths.push((generation, entry.path()));
    }
    Ok(paths)
}
