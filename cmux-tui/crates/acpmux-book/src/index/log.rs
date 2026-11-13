//! CRC-framed bounded log records and recoverable generation changes.
use super::{DiskSnapshot, IndexRecord, RowKey, SortedSnapshot, Summary, SummaryIndex, codec};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

pub struct IndexLog {
    file: File,
    path: PathBuf,
    next_seq: u64,
    offset: u64,
    oldest_seq: u64,
}

impl IndexLog {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let requested = path.as_ref();
        let snapshot = DiskSnapshot::open(requested.with_extension("snap"))?;
        let seq = snapshot.as_ref().map_or(0, |snapshot| snapshot.seq());
        let offset = snapshot.as_ref().map_or(0, |snapshot| snapshot.head.log_offset);
        let path = match snapshot.as_ref().and_then(|snapshot| snapshot.head.log_name.as_deref()) {
            Some(name) => {
                if Path::new(name).file_name().and_then(|name| name.to_str()) != Some(name) {
                    return Err(codec::invalid("snapshot log name"));
                }
                requested.parent().unwrap_or_else(|| Path::new(".")).join(name)
            }
            None => requested.to_owned(),
        };
        Self::open_tail(path, seq, offset)
    }

    pub(super) fn open_tail(path: PathBuf, seq: u64, covered: u64) -> io::Result<Self> {
        let mut file =
            OpenOptions::new().create(true).truncate(false).read(true).write(true).open(&path)?;
        if file.metadata()?.len() < covered {
            return Err(codec::invalid("log shorter than snapshot offset"));
        }
        let mut reader = BufReader::new(file.try_clone()?);
        reader.seek(SeekFrom::Start(covered))?;
        let mut offset = covered;
        let mut next_seq = seq;
        let mut oldest_seq = seq.saturating_add(1);
        loop {
            match codec::read(&mut reader) {
                Ok(Some((record, len))) if record.seq > next_seq => {
                    if offset == covered {
                        oldest_seq = record.seq;
                    }
                    offset += len as u64;
                    next_seq = record.seq;
                }
                Ok(None) => break,
                Ok(Some(_)) => break,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::UnexpectedEof
                            | io::ErrorKind::InvalidData
                            | io::ErrorKind::InvalidInput
                            | io::ErrorKind::Other
                    ) =>
                {
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
        Ok(Self { file, path, next_seq, offset, oldest_seq })
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

    /// A fresh generation exists durably before the snapshot selects it. The
    /// old log is deleted only after the snapshot rename and directory sync.
    pub fn compact(
        &mut self,
        snapshot_path: impl AsRef<Path>,
        index: &SummaryIndex,
    ) -> io::Result<()> {
        self.sync()?;
        let parent = self.path.parent().unwrap_or_else(|| Path::new(".")).to_owned();
        let name = format!("index.log.{}", index.seq());
        let generation = parent.join(&name);
        if generation == self.path {
            return Ok(());
        }
        let file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&generation)?;
        file.sync_all()?;
        File::open(&parent)?.sync_all()?;
        SortedSnapshot::write_with_offset_and_name(snapshot_path, index, 0, Some(&name))?;
        let old = std::mem::replace(&mut self.path, generation);
        self.file = file;
        self.offset = 0;
        self.next_seq = index.seq();
        self.oldest_seq = index.seq().saturating_add(1);
        fs::remove_file(old)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    }
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
    while let Ok(Some((record, _))) = codec::read(&mut reader) {
        if record.seq <= index.seq() {
            continue;
        }
        if record.gone {
            index = index
                .remove_row(record.seq, &RowKey::new(record.origin, record.chat_id))
                .unwrap_or(index);
            index.seq = record.seq;
        } else {
            index = index.apply(record.seq, record.summary);
        }
    }
    Ok(index)
}
