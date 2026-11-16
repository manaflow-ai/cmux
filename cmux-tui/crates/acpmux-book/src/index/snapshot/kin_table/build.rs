//! Staged ancestor expansion using fixed records and sorted merge joins.

use super::sort::{Record, SortedFile, Sorter};
use super::{ENTRY_BYTES, Entry, FAMILY_KIND, FORK_KIND, MAX_DEPTH, invalid, key_fingerprint};
use crate::index::Summary;
use std::cmp::Ordering;
use std::io;
use std::path::{Path, PathBuf};

type Fingerprint = (u64, u32);

#[derive(Clone, Copy, Eq, Ord, PartialEq, PartialOrd)]
struct Edge {
    child: Fingerprint,
    parent: Fingerprint,
}

impl Record for Edge {
    const WIDTH: usize = 24;
    fn encode(self, bytes: &mut [u8]) {
        write_fingerprint(self.child, &mut bytes[..12]);
        write_fingerprint(self.parent, &mut bytes[12..]);
    }
    fn decode(bytes: &[u8]) -> io::Result<Self> {
        Ok(Self { child: read_fingerprint(&bytes[..12])?, parent: read_fingerprint(&bytes[12..])? })
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
struct Level {
    entry: Entry,
    own: Fingerprint,
    eligible: bool,
}

impl Ord for Level {
    fn cmp(&self, other: &Self) -> Ordering {
        self.fingerprint()
            .cmp(&other.fingerprint())
            .then_with(|| EntryRecord(self.entry).cmp(&EntryRecord(other.entry)))
            .then_with(|| self.own.cmp(&other.own))
            .then_with(|| self.eligible.cmp(&other.eligible))
    }
}

impl PartialOrd for Level {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Level {
    fn fingerprint(self) -> Fingerprint {
        (self.entry.hash, self.entry.check)
    }
}

impl Record for Level {
    const WIDTH: usize = ENTRY_BYTES + 12 + 1;
    fn encode(self, bytes: &mut [u8]) {
        self.entry.encode(&mut bytes[..ENTRY_BYTES]);
        write_fingerprint(self.own, &mut bytes[ENTRY_BYTES..ENTRY_BYTES + 12]);
        bytes[ENTRY_BYTES + 12] = u8::from(self.eligible);
    }
    fn decode(bytes: &[u8]) -> io::Result<Self> {
        if bytes[ENTRY_BYTES + 12] > 1 {
            return Err(invalid("kin eligibility"));
        }
        Ok(Self {
            entry: Entry::decode(&bytes[..ENTRY_BYTES])?,
            own: read_fingerprint(&bytes[ENTRY_BYTES..ENTRY_BYTES + 12])?,
            eligible: bytes[ENTRY_BYTES + 12] != 0,
        })
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
struct EntryRecord(Entry);

impl Ord for EntryRecord {
    fn cmp(&self, other: &Self) -> Ordering {
        let entry = self.0;
        let other = other.0;
        (entry.hash, entry.offset, entry.check, entry.kind, entry.depth, entry.activity, entry.len)
            .cmp(&(
                other.hash,
                other.offset,
                other.check,
                other.kind,
                other.depth,
                other.activity,
                other.len,
            ))
    }
}

impl PartialOrd for EntryRecord {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Record for EntryRecord {
    const WIDTH: usize = ENTRY_BYTES;
    fn encode(self, bytes: &mut [u8]) {
        self.0.encode(bytes);
    }
    fn decode(bytes: &[u8]) -> io::Result<Self> {
        Entry::decode(bytes).map(Self)
    }
}

pub(in crate::index) struct Builder {
    directory: PathBuf,
    edges: Sorter<Edge>,
    first_level: Sorter<Level>,
    output: Sorter<EntryRecord>,
}

impl Builder {
    #[cfg(test)]
    pub(in crate::index) fn new() -> io::Result<Self> {
        Self::in_directory(&std::env::temp_dir())
    }

    pub(in crate::index) fn in_directory(directory: &Path) -> io::Result<Self> {
        Ok(Self {
            directory: directory.to_owned(),
            edges: Sorter::in_directory(directory)?,
            first_level: Sorter::in_directory(directory)?,
            output: Sorter::in_directory(directory)?,
        })
    }

    pub(in crate::index) fn push(
        &mut self,
        summary: &Summary,
        offset: u64,
        len: usize,
    ) -> io::Result<()> {
        let key = summary.key();
        key.validate()?;
        let len = u16::try_from(len).map_err(|_| invalid("kin frame length"))?;
        let eligible = !summary.pinned && !summary.is_live();
        let entry = |fingerprint: Fingerprint, kind| Entry {
            hash: fingerprint.0,
            activity: summary.last_activity,
            offset,
            check: fingerprint.1,
            len,
            depth: 1,
            kind,
        };
        if let Some(parent) = &summary.parent
            && parent != &key
        {
            let child = key_fingerprint(&key, FAMILY_KIND);
            let parent = key_fingerprint(parent, FAMILY_KIND);
            // Hot rows still supply edges for a cold descendant's ancestor path.
            self.edges.push(Edge { child, parent })?;
            self.first_level.push(Level {
                entry: entry(parent, FAMILY_KIND),
                own: child,
                eligible,
            })?;
        }
        if eligible && let Some(fork) = &summary.fork_of {
            let source = key_fingerprint(&fork.key, FORK_KIND);
            if source != key_fingerprint(&key, FORK_KIND) {
                self.output.push(EntryRecord(entry(source, FORK_KIND)))?;
            }
        }
        Ok(())
    }

    pub(in crate::index) fn finish(self) -> io::Result<SortedEntries> {
        let mut edges = self.edges.finish()?;
        let mut level = self.first_level.finish()?;
        let mut output = self.output;
        for depth in 1..=MAX_DEPTH {
            if level.count == 0 {
                break;
            }
            edges.rewind()?;
            let mut edge = edges.next()?;
            let mut next = Sorter::<Level>::in_directory(&self.directory)?;
            while let Some(record) = level.next()? {
                if record.eligible && record.fingerprint() != record.own {
                    output.push(EntryRecord(record.entry))?;
                }
                if depth == MAX_DEPTH {
                    continue;
                }
                while edge.is_some_and(|edge| edge.child < record.fingerprint()) {
                    edge = edges.next()?;
                }
                if let Some(edge) = edge.filter(|edge| edge.child == record.fingerprint()) {
                    let mut entry = record.entry;
                    entry.hash = edge.parent.0;
                    entry.check = edge.parent.1;
                    entry.depth = depth + 1;
                    next.push(Level { entry, own: record.own, eligible: record.eligible })?;
                }
            }
            if depth == MAX_DEPTH {
                break;
            }
            level = next.finish()?;
        }
        // Keep the nearest depth: a short cycle must not manufacture a
        // depth-64 deeper pointer back into itself on a later traversal.
        let file = output.finish_unique_by(|left, right| {
            let left = left.0;
            let right = right.0;
            (left.hash, left.check, left.kind, left.offset)
                == (right.hash, right.check, right.kind, right.offset)
        })?;
        Ok(SortedEntries { count: file.count, file })
    }
}

/// Owns the final sorted temporary file until the table writer finishes.
pub(in crate::index) struct SortedEntries {
    file: SortedFile<EntryRecord>,
    pub(in crate::index) count: u64,
}

impl SortedEntries {
    pub(in crate::index) fn next(&mut self) -> io::Result<Option<Entry>> {
        Ok(self.file.next()?.map(|record| record.0))
    }
}

fn write_fingerprint((hash, check): Fingerprint, bytes: &mut [u8]) {
    bytes[..8].copy_from_slice(&hash.to_le_bytes());
    bytes[8..12].copy_from_slice(&check.to_le_bytes());
}

fn read_fingerprint(bytes: &[u8]) -> io::Result<Fingerprint> {
    let hash = u64::from_le_bytes(bytes[..8].try_into().map_err(|_| invalid("kin edge hash"))?);
    let check = u32::from_le_bytes(bytes[8..12].try_into().map_err(|_| invalid("kin edge check"))?);
    Ok((hash, check))
}
