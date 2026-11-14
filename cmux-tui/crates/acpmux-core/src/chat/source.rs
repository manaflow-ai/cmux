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
    /// A file source inside a derived book must retain its path and inode at swap.
    fn file_path(&self) -> Option<&Path> {
        None
    }
    /// At most `max` bytes of the line that starts at `place`, from `offset` in it, and whether
    /// the line ends there. A queue head, a waiting prompt's `blob` and a body read back use it,
    /// so none of them reads a line whole. A source that cannot answers `Unsupported`.
    fn read_at(&mut self, _place: u64, _offset: u64, _max: usize) -> io::Result<Piece> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "this source reads no part of a line"))
    }
}

/// Part of one line, from [`RawSource::read_at`]. `bytes` holds no newline.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Piece {
    pub bytes: Vec<u8>,
    /// The line ends where `bytes` ends.
    pub ends: bool,
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
    path: std::path::PathBuf,
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
            path,
            cursor: 0,
            looked: 0,
            stats: ReadStats::default(),
        })
    }

    pub fn stats(&self) -> ReadStats {
        self.stats
    }

    fn read_exact_at(&mut self, offset: u64, bytes: &mut [u8]) -> io::Result<()> {
        self.file.seek(SeekFrom::Start(offset))?;
        self.file.read_exact(bytes)?;
        self.stats.bytes = self.stats.bytes.saturating_add(bytes.len() as u64);
        Ok(())
    }
}

impl RawSource for FileSource {
    fn file_path(&self) -> Option<&Path> {
        Some(&self.path)
    }

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
        self.read_exact_at(base, &mut bytes)?;
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
            self.read_exact_at(place, &mut bytes)?;
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
        self.read_exact_at(place - 1, &mut byte)?;
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

    fn read_at(&mut self, place: u64, offset: u64, max: usize) -> io::Result<Piece> {
        let length = self.hint()?;
        let at = place.checked_add(offset).ok_or_else(|| invalid("raw position overflow"))?;
        if at > length {
            return Err(invalid("a part of a line past the file"));
        }
        let count = usize::try_from((length - at).min(max as u64)).map_err(io::Error::other)?;
        let mut bytes = vec![0; count];
        self.read_exact_at(at, &mut bytes)?;
        let ends = match bytes.iter().position(|byte| *byte == b'\n') {
            Some(newline) => {
                bytes.truncate(newline);
                true
            }
            None => false,
        };
        Ok(Piece { bytes, ends })
    }
}

#[cfg(test)]
mod tests;
