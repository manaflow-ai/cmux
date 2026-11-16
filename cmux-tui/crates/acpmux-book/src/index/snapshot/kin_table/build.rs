//! Staged ancestor expansion using fixed records and sorted merge joins.

use super::sort::{Record, SortedFile, Sorter};
use super::{
    ENTRY_BYTES, Entry, FAMILY_KIND, FORK_KIND, MAX_DEPTH, invalid, key_fingerprint, take_bytes,
};
use crate::index::Summary;
use std::cmp::Ordering;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

type Fingerprint = (u64, u32);

#[derive(Clone, Copy, Eq, Ord, PartialEq, PartialOrd)]
struct Edge {
    child: Fingerprint,
    parent: Fingerprint,
}

impl Record for Edge {
    const WIDTH: usize = 24;
    fn encode(self, mut bytes: &mut [u8]) -> io::Result<()> {
        write_fingerprint(self.child, &mut bytes)?;
        write_fingerprint(self.parent, &mut bytes)
    }
    fn decode(mut bytes: &[u8]) -> io::Result<Self> {
        Ok(Self { child: read_fingerprint(&mut bytes)?, parent: read_fingerprint(&mut bytes)? })
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
    fn encode(self, mut bytes: &mut [u8]) -> io::Result<()> {
        let mut entry = [0; ENTRY_BYTES];
        self.entry.encode(&mut entry)?;
        bytes.write_all(&entry)?;
        write_fingerprint(self.own, &mut bytes)?;
        bytes.write_all(&[u8::from(self.eligible)])
    }
    fn decode(mut bytes: &[u8]) -> io::Result<Self> {
        let entry = Entry::decode(&take_bytes::<ENTRY_BYTES>(&mut bytes)?)?;
        let own = read_fingerprint(&mut bytes)?;
        let [eligible] = take_bytes(&mut bytes)?;
        if eligible > 1 {
            return Err(invalid("kin eligibility"));
        }
        Ok(Self { entry, own, eligible: eligible != 0 })
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
    fn encode(self, bytes: &mut [u8]) -> io::Result<()> {
        self.0.encode(bytes)
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
            // Ineligible rows still supply edges for a descendant's ancestor path.
            self.edges.push(Edge { child, parent })?;
            // A pinned or live row contributes its edge above, but it
            // cannot itself be cold under this snapshot. Do not enqueue its
            // own level record: descendants still join through this edge,
            // while the external sorter does not carry an ineligible record
            // through every closure level.
            if eligible {
                self.first_level.push(Level {
                    entry: entry(parent, FAMILY_KIND),
                    own: child,
                    eligible,
                })?;
            }
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

fn write_fingerprint((hash, check): Fingerprint, bytes: &mut &mut [u8]) -> io::Result<()> {
    bytes.write_all(&hash.to_le_bytes())?;
    bytes.write_all(&check.to_le_bytes())
}

fn read_fingerprint(bytes: &mut &[u8]) -> io::Result<Fingerprint> {
    let hash = u64::from_le_bytes(take_bytes(bytes)?);
    let check = u32::from_le_bytes(take_bytes(bytes)?);
    Ok((hash, check))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, activity: u64) -> Summary {
        let mut row = Summary::new(id);
        row.last_activity = activity;
        row.state = "closed".to_owned();
        row
    }

    fn check_truncated_record<R: Record>(record: R) {
        let mut bytes = vec![0; R::WIDTH];
        record.encode(&mut bytes).unwrap();
        assert!(R::decode(&bytes).is_ok_and(|decoded| decoded == record));
        for length in 0..R::WIDTH {
            assert!(record.encode(&mut bytes[..length]).is_err());
            assert!(R::decode(&bytes[..length]).is_err());
        }
    }

    #[test]
    fn fixed_records_reject_every_truncation_without_panicking() {
        check_truncated_record(Edge { child: (1, 2), parent: (3, 4) });
        let entry = Entry {
            hash: 5,
            activity: 6,
            offset: 7,
            check: 8,
            len: 9,
            depth: 10,
            kind: FAMILY_KIND,
        };
        check_truncated_record(EntryRecord(entry));
        check_truncated_record(Level { entry, own: (11, 12), eligible: true });
    }

    #[test]
    fn cold_descendant_joins_through_pinned_and_live_edges() {
        let mut root = row("builder-bridge-root", 1);
        root.state = "closed".to_owned();
        let mut live = row("builder-bridge-live", 2);
        live.state = "running".to_owned();
        live.parent = Some(root.key());
        let mut pinned = row("builder-bridge-pinned", 3);
        pinned.pinned = true;
        pinned.parent = Some(live.key());
        let mut leaf = row("builder-bridge-leaf", 4);
        leaf.parent = Some(pinned.key());

        let directory = tempfile::tempdir().unwrap();
        let mut builder = Builder::in_directory(directory.path()).unwrap();
        for (offset, summary) in [(4096, root), (8192, live), (12_288, pinned), (16_384, leaf)] {
            builder.push(&summary, offset, 128).unwrap();
        }
        let mut entries = builder.finish().unwrap();
        let mut leaf_entries = Vec::new();
        while let Some(entry) = entries.next().unwrap() {
            if entry.offset == 16_384 {
                leaf_entries.push(entry);
            } else {
                assert!(entry.offset != 8192 && entry.offset != 12_288);
            }
        }
        assert_eq!(leaf_entries.len(), 3);
        // The persisted order is ancestor hash, not ancestry depth.
        let mut depths: Vec<_> = leaf_entries.iter().map(|entry| entry.depth).collect();
        depths.sort_unstable();
        assert_eq!(depths, vec![1, 2, 3]);
    }
}
