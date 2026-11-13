//! Ordered whole lines in source places. A chunk owns one buffer and no per-line table.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]
#![forbid(unsafe_code)]

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::ops::Range;
use std::path::Path;

pub const CHUNK_BYTES: usize = 256 * 1024;
/// Maps one whole line and its byte position to source places. A v1 source can obtain
/// its seq from the line itself; a file uses the byte position. No table grows with lines.
pub type Places = fn(&[u8], u64) -> io::Result<Range<u64>>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
    pub bytes: Range<usize>,
    pub start: u64,
    pub end: u64,
}

pub struct Chunk {
    bytes: Vec<u8>,
    base: u64,
    places: Places,
    pub at_end: bool,
    pub hint: u64,
    /// The source stamp captured while this chunk was read.
    pub stamp: u64,
}

impl Chunk {
    pub fn new(bytes: Vec<u8>, base: u64, places: Places, at_end: bool, hint: u64) -> Self {
        Self { bytes, base, places, at_end, hint, stamp: 0 }
    }

    pub fn with_stamp(
        bytes: Vec<u8>,
        base: u64,
        places: Places,
        at_end: bool,
        hint: u64,
        stamp: u64,
    ) -> Self {
        Self { bytes, base, places, at_end, hint, stamp }
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn lines(&self) -> Lines<'_> {
        Lines { chunk: self, at: 0 }
    }

    pub fn resident_bytes(&self) -> usize {
        self.bytes.capacity()
    }

    /// Validate a notice before using it. A source chunk must follow the same invariants.
    pub fn validate(&self, after: u64) -> io::Result<()> {
        let mut previous = after;
        let mut count = 0usize;
        for line in self.lines() {
            let line = line?;
            if line.start < previous || line.start >= line.end {
                return Err(invalid("raw places do not grow"));
            }
            previous = line.end;
            count = count.saturating_add(1);
        }
        if self.bytes.len() > CHUNK_BYTES && count != 1 {
            return Err(invalid("raw chunk exceeds its bound"));
        }
        Ok(())
    }
}

pub struct Lines<'a> {
    chunk: &'a Chunk,
    at: usize,
}

impl Iterator for Lines<'_> {
    type Item = io::Result<Line>;
    fn next(&mut self) -> Option<Self::Item> {
        let rest = self.chunk.bytes.get(self.at..)?;
        if rest.is_empty() {
            return None;
        }
        let start = self.at;
        let Some(newline) = rest.iter().position(|byte| *byte == b'\n') else {
            self.at = self.chunk.bytes.len();
            return Some(Err(invalid("incomplete raw line")));
        };
        let length = newline.saturating_add(1);
        self.at = start.saturating_add(length);
        let bytes = rest.get(..length)?;
        let position = self.chunk.base.checked_add(start as u64);
        Some(position.ok_or_else(|| invalid("raw position overflow")).and_then(|position| {
            (self.chunk.places)(bytes, position).map(|places| Line {
                bytes: start..self.at,
                start: places.start,
                end: places.end,
            })
        }))
    }
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

pub fn byte_places(bytes: &[u8], start: u64) -> io::Result<Range<u64>> {
    let end = start.checked_add(bytes.len() as u64).ok_or_else(|| invalid("raw end overflow"))?;
    Ok(start..end)
}

pub trait RawSource: Send + 'static {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk>;
    /// Whether a previously delivered line end still exists. This is not an end search.
    fn holds(&mut self, place: u64) -> io::Result<bool>;
    /// A growth hint, not a whole-line end. Equality with the last at_end read avoids spins.
    fn hint(&self) -> io::Result<u64>;
    /// Sync before any checkpoint or patch derived from these lines becomes durable.
    fn sync_through(&mut self, place: u64) -> io::Result<()>;
    fn identity(&self) -> &[u8];
    /// Changes whenever a previously delivered line can read differently.
    fn stamp(&self) -> u64;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ReadStats {
    pub bytes: u64,
    pub scanned: u64,
    pub holds_bytes: u64,
}

/// An append-only file. No open or read walks to its last newline. The only retained
/// scan state is the cursor and how far past it we have looked without a newline.
pub struct FileSource {
    file: File,
    identity: Vec<u8>,
    cursor: u64,
    looked: u64,
    stats: ReadStats,
}

impl FileSource {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        let path = path.canonicalize()?;
        let mut identity = String::from("file:");
        use std::fmt::Write;
        for byte in path.as_os_str().as_encoded_bytes() {
            write!(&mut identity, "{byte:02x}").map_err(io::Error::other)?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let metadata = file.metadata()?;
            write!(&mut identity, ":{}:{}", metadata.dev(), metadata.ino())
                .map_err(io::Error::other)?;
        }
        Ok(Self {
            file,
            identity: identity.into_bytes(),
            cursor: 0,
            looked: 0,
            stats: ReadStats::default(),
        })
    }

    pub fn stats(&self) -> ReadStats {
        self.stats
    }

    fn read_at(&mut self, offset: u64, bytes: &mut [u8]) -> io::Result<()> {
        self.file.seek(SeekFrom::Start(offset))?;
        self.file.read_exact(bytes)?;
        self.stats.bytes = self.stats.bytes.saturating_add(bytes.len() as u64);
        Ok(())
    }
}

impl RawSource for FileSource {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        let length = self.hint()?;
        let mut budget = CHUNK_BYTES;
        if place != self.cursor || length < self.looked {
            if !self.holds(place)? {
                return Err(invalid("raw cursor no longer exists"));
            }
            budget -= usize::from(place != 0);
            self.cursor = place;
            self.looked = place;
        }
        if place > length {
            return Err(invalid("raw cursor past file"));
        }
        if self.looked == length {
            return Ok(Chunk::with_stamp(
                Vec::new(),
                place,
                byte_places,
                true,
                length,
                self.stamp(),
            ));
        }
        let prefix = self.looked - place;
        let base = self.looked;
        let count =
            usize::try_from((length - base).min(budget as u64)).map_err(io::Error::other)?;
        let mut bytes = vec![0; count];
        self.read_at(base, &mut bytes)?;
        // With an unfinished prefix, finish just that line. With none, return every
        // whole line in the chunk. No partial prefix is read again until it completes.
        let newline = if prefix != 0 {
            bytes.iter().position(|byte| *byte == b'\n')
        } else {
            bytes.iter().rposition(|byte| *byte == b'\n')
        };
        let scanned = if prefix != 0 { newline.map_or(count, |at| at + 1) } else { count };
        self.stats.scanned = self.stats.scanned.saturating_add(scanned as u64);
        self.looked = base + scanned as u64;
        let Some(newline) = newline else {
            return Ok(Chunk::with_stamp(
                Vec::new(),
                place,
                byte_places,
                self.looked == length,
                length,
                self.stamp(),
            ));
        };
        let end = base + newline as u64 + 1;
        if prefix != 0 {
            // Reconstitute the completed line in the same allocation. Oversized lines
            // allocate only here; every prior scan yielded to the actor's mailbox.
            let size = usize::try_from(end - place).map_err(io::Error::other)?;
            bytes.resize(size, 0);
            self.read_at(place, &mut bytes)?;
        } else {
            bytes.truncate(newline + 1);
        }
        self.cursor = end;
        Ok(Chunk::with_stamp(
            bytes,
            place,
            byte_places,
            self.looked == length,
            length,
            self.stamp(),
        ))
    }

    fn holds(&mut self, place: u64) -> io::Result<bool> {
        if place > self.file.metadata()?.len() {
            return Ok(false);
        }
        if place == 0 {
            return Ok(true);
        }
        let mut byte = [0];
        self.read_at(place - 1, &mut byte)?;
        self.stats.holds_bytes = self.stats.holds_bytes.saturating_add(1);
        Ok(byte == [b'\n'])
    }

    fn hint(&self) -> io::Result<u64> {
        Ok(self.file.metadata()?.len())
    }

    fn sync_through(&mut self, place: u64) -> io::Result<()> {
        if !self.holds(place)? {
            return Err(invalid("raw source has not reached this place"));
        }
        self.file.sync_all()
    }

    fn identity(&self) -> &[u8] {
        &self.identity
    }
    fn stamp(&self) -> u64 {
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    // The leading decimal is the test source's seq, with arbitrary gaps.
    fn seq_places(line: &[u8], _: u64) -> io::Result<Range<u64>> {
        let seq = line.split(|byte| *byte == b' ').next().ok_or_else(|| invalid("missing seq"))?;
        let start: u64 = std::str::from_utf8(seq)
            .map_err(io::Error::other)?
            .parse()
            .map_err(io::Error::other)?;
        Ok(start..start.checked_add(1).ok_or_else(|| invalid("seq overflow"))?)
    }

    struct GappedSource {
        bytes: Vec<u8>,
        stamp: u64,
        synced: u64,
    }
    impl RawSource for GappedSource {
        fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
            let mut bytes = Vec::with_capacity(CHUNK_BYTES);
            let mut at_end = true;
            for line in self.bytes.split_inclusive(|byte| *byte == b'\n') {
                if seq_places(line, 0)?.start < place {
                    continue;
                }
                if !bytes.is_empty() && bytes.len() + line.len() > CHUNK_BYTES {
                    at_end = false;
                    break;
                }
                bytes.extend_from_slice(line);
            }
            Ok(Chunk::with_stamp(bytes, 0, seq_places, at_end, self.hint()?, self.stamp))
        }
        fn hint(&self) -> io::Result<u64> {
            self.bytes
                .split_inclusive(|byte| *byte == b'\n')
                .next_back()
                .map(|line| seq_places(line, 0).map(|range| range.end))
                .unwrap_or(Ok(0))
        }
        fn holds(&mut self, place: u64) -> io::Result<bool> {
            Ok(place <= self.hint()?)
        }
        fn sync_through(&mut self, place: u64) -> io::Result<()> {
            if !self.holds(place)? {
                return Err(invalid("sync past end"));
            }
            self.synced = self.synced.max(place);
            Ok(())
        }
        fn identity(&self) -> &[u8] {
            b"test:gapped"
        }
        fn stamp(&self) -> u64 {
            self.stamp
        }
    }

    #[test]
    fn gapped_places_keep_the_same_lines_in_one_buffer() -> io::Result<()> {
        let bytes = b"100 one\n900 two\n9000 three\n";
        let mut raw = tempfile::NamedTempFile::new()?;
        raw.write_all(bytes)?;
        let mut file = FileSource::open(raw.path())?;
        let mut gaps = GappedSource { bytes: bytes.to_vec(), stamp: 1, synced: 0 };
        let chunk = gaps.read_chunk(0)?;
        chunk.validate(0)?;
        assert_eq!(file.read_chunk(0)?.bytes(), chunk.bytes());
        let mut lines = chunk.lines();
        assert_eq!(lines.next().ok_or_else(|| invalid("missing line"))??.start, 100);
        assert_eq!(lines.next().ok_or_else(|| invalid("missing line"))??.end, 901);
        assert_eq!(file.read_chunk(8)?.bytes(), gaps.read_chunk(101)?.bytes());
        assert_eq!(gaps.hint()?, 9001);
        gaps.sync_through(901)?;
        assert_eq!(gaps.synced, 901);
        assert!(chunk.validate(101).is_err());
        Ok(())
    }

    #[test]
    fn a_large_line_yields_between_bounded_scans() -> io::Result<()> {
        let mut raw = tempfile::NamedTempFile::new()?;
        raw.write_all(&vec![b'x'; CHUNK_BYTES * 3])?;
        raw.write_all(b"\npartial")?;
        let mut source = FileSource::open(raw.path())?;
        assert_eq!(source.stats().bytes, 0);
        for _ in 0..3 {
            let chunk = source.read_chunk(0)?;
            assert!(!chunk.at_end);
            assert!(chunk.bytes().is_empty());
        }
        let large = source.read_chunk(0)?;
        large.validate(0)?;
        assert_eq!(large.lines().count(), 1);
        let cursor = CHUNK_BYTES as u64 * 3 + 1;
        assert!(source.holds(cursor)?);
        assert!(!source.holds(cursor + 1)?);
        let partial = source.read_chunk(cursor)?;
        assert!(partial.at_end && partial.bytes().is_empty());
        raw.write_all(b"\n")?;
        assert_eq!(source.read_chunk(cursor)?.bytes(), b"partial\n");
        Ok(())
    }

    #[test]
    fn long_partial_append_scans_each_byte_once() -> io::Result<()> {
        let mut raw = tempfile::NamedTempFile::new()?;
        let mut source = FileSource::open(raw.path())?;
        let piece = vec![b'x'; 100_000];
        for _ in 0..100 {
            raw.write_all(&piece)?;
            let chunk = source.read_chunk(0)?;
            assert!(chunk.at_end && chunk.bytes().is_empty());
        }
        assert_eq!(source.stats().scanned, 10_000_000);
        raw.write_all(b"\n")?;
        let chunk = source.read_chunk(0)?;
        assert!(chunk.at_end);
        assert_eq!(chunk.bytes().len(), 10_000_001);
        assert_eq!(source.stats().scanned, 10_000_001);
        assert!(source.read_chunk(10_000_001)?.bytes().is_empty());
        Ok(())
    }

    #[test]
    fn a_gigabyte_growth_costs_one_chunk_and_holds_one_byte() -> io::Result<()> {
        let mut raw = tempfile::NamedTempFile::new()?;
        raw.write_all(b"a\n")?;
        let mut source = FileSource::open(raw.path())?;
        assert!(source.read_chunk(0)?.at_end);
        // Sparse history: only the next chunk is relevant to this call's budget.
        raw.write_all(&vec![b'\n'; CHUNK_BYTES])?;
        raw.as_file().set_len(1 << 30)?;
        let before = source.stats();
        let chunk = source.read_chunk(2)?;
        assert_eq!(chunk.bytes().len(), CHUNK_BYTES);
        assert!(!chunk.at_end);
        assert_eq!(source.stats().bytes - before.bytes, CHUNK_BYTES as u64);
        let before = source.stats();
        assert!(source.holds(2)?);
        assert_eq!(source.stats().bytes - before.bytes, 1);
        Ok(())
    }

    #[test]
    fn tiny_lines_need_no_per_line_allocation() -> io::Result<()> {
        let chunk = Chunk::new(vec![b'\n'; CHUNK_BYTES], 0, byte_places, true, CHUNK_BYTES as u64);
        chunk.validate(0)?;
        assert_eq!(chunk.lines().count(), CHUNK_BYTES);
        assert_eq!(chunk.resident_bytes(), CHUNK_BYTES);
        Ok(())
    }

    #[test]
    fn v2_pr03a_source_read_bounds() -> io::Result<()> {
        let mut measured = Vec::new();
        for rows in [40u64, 2_000_000] {
            let mut raw = tempfile::NamedTempFile::new()?;
            let cursor = rows * 80;
            raw.seek(SeekFrom::Start(cursor - 1))?;
            raw.write_all(b"\n")?;
            let mut source = FileSource::open(raw.path())?;
            assert!(source.read_chunk(cursor)?.at_end);
            raw.write_all(&vec![b'\n'; CHUNK_BYTES])?;
            raw.as_file().set_len(cursor + (1 << 30))?;
            let before = source.stats();
            let chunk = source.read_chunk(cursor)?;
            let read = source.stats().bytes - before.bytes;
            assert_eq!(chunk.bytes().len(), CHUNK_BYTES);
            assert!(!chunk.at_end);
            assert!(read <= CHUNK_BYTES as u64);
            let before = source.stats();
            assert!(source.holds(cursor)?);
            let holds = source.stats().bytes - before.bytes;
            assert_eq!(holds, 1);
            measured.push((read, holds));
            eprintln!(
                "v2.pr03a.source_read_bounds rows={rows} appended_bytes=1073741824 read_bytes={read} holds_bytes={holds}"
            );
        }
        let small = measured.first().ok_or_else(|| invalid("small measurement"))?;
        let god = measured.last().ok_or_else(|| invalid("god measurement"))?;
        assert_eq!(small, god);
        eprintln!(
            "v2.pr03a.source_read_bounds read_ratio={} holds_ratio={}",
            god.0 as f64 / small.0 as f64,
            god.1 as f64 / small.1 as f64
        );
        if let Ok(path) = std::env::var("V2_GATE_OUT") {
            let mut output = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
            writeln!(
                output,
                "{{\"name\":\"v2.pr03a.source_read_bounds\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"bytes\"}}",
                small.0, god.0
            )?;
        }
        Ok(())
    }
}
