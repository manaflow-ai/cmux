//! A Claude Code or Codex transcript followed as it grows, for the chats page's text (`text.rs`).
//!
//! The first read of a transcript folds it whole, as [`crate::adopt_replay::read`] does (its
//! newest [`MAX_BYTES`], its newest [`MAX_TURNS`] turns). Every read after it starts at the byte
//! offset the last one ended at and folds only the lines appended since, by the same fold, so a
//! change to a 1 GB chat reads and parses what a change to a small one does: the lines written
//! since. That is how the chat index follows a transcript (`cmux_chat_index`'s
//! `lines::fold_lines`). A transcript replaced (another device or inode), cut shorter than the
//! offset or rewritten under it (the byte before the offset no longer ends a line) is read whole
//! again, as is a Codex rollout whose turns move between its event messages and its items.
//!
//! What it holds between reads is small: the offset, the newest turn (the one later lines can
//! still add an answer to) and the offset each turn in the window starts at, so a turn that falls
//! out of the newest [`MAX_BYTES`] or [`MAX_TURNS`] leaves the window as a whole read would drop
//! it, and a hit's turn number stays the one `_acpmux/chat_transcript` shows.

use std::collections::VecDeque;
use std::fs::File;
use std::io::{BufRead, BufReader, Read as _, Seek, SeekFrom};
use std::path::Path;

use cmux_chat_index::AdapterKind;
use cmux_chat_index::transcript::Turn;

use crate::adopt_replay::{Fold, ItemLine, MAX_BYTES, MAX_TURNS};

/// The bytes at the start of a transcript and before the last read's end that a read checks are
/// unchanged: a rewrite that keeps the line ends where they were is read whole again.
const GUARD_BYTES: u64 = 4096;

/// The adopt reader's family of a harness whose transcript is followed: Claude Code's and
/// Codex's (`super::transcript_turns` reads every other harness whole).
pub fn family(harness: AdapterKind) -> Option<&'static str> {
    match harness {
        AdapterKind::ClaudeCode => Some("claude"),
        AdapterKind::Codex => Some("codex"),
        _ => None,
    }
}

/// What one read found.
#[derive(Debug)]
pub enum Read {
    /// The transcript was read whole: its turns in the window, the first numbered `first`.
    Whole { first: u32, turns: Vec<Turn> },
    /// Turn `from` (the newest the last read held) went on or the lines after it started more:
    /// turn `from` and every one after it, as they are now. The window starts at turn `first`.
    Tail { from: u32, first: u32, turns: Vec<Turn> },
}

/// A followed transcript: where the last read ended and what it left open.
#[derive(Debug)]
pub struct Follow {
    family: &'static str,
    /// The file's identity ([`file_id`]): another file is read whole.
    file: (u64, u64),
    /// The end of the last complete line read.
    offset: u64,
    fold: Fold,
    turns: Window,
    items: Window,
    /// The doc is made of Codex's items (no event-message turn is in the window).
    reads_items: bool,
    /// The Codex lines that decide how a read starting at the cut folds items, oldest first: runs
    /// of annotated lines and of plain prompts ([`ItemLine`]), each kept as where its last line
    /// starts (the one that stays inside the newest [`MAX_BYTES`] longest). A plain prompt with
    /// no annotated line between the cut and it would fold as an item in a whole read.
    marks: VecDeque<(u64, ItemLine)>,
    /// A hash of the file's first and last [`GUARD_BYTES`] before `offset` ([`guard`]).
    guard: u64,
    /// Bytes read since this transcript was first followed (tests count them).
    pub bytes_read: u64,
}

/// The offset each turn (or Codex item) in the window starts at, oldest first.
#[derive(Debug, Default)]
struct Window {
    /// The number of `starts[0]` among every turn folded.
    first: usize,
    starts: VecDeque<u64>,
}

impl Window {
    fn push(&mut self, start: u64) {
        self.starts.push_back(start);
        if self.starts.len() > MAX_TURNS {
            self.starts.pop_front();
            self.first += 1;
        }
    }

    /// Lets go of every turn a whole read of a `len`-byte file would not hold: one whose line
    /// starts at or before the cut (that read skips the line the cut falls in).
    fn trim(&mut self, len: u64) {
        let cut = len.saturating_sub(MAX_BYTES);
        while len > MAX_BYTES && self.starts.front().is_some_and(|&start| start <= cut) {
            self.starts.pop_front();
            self.first += 1;
        }
    }
}

/// Reads `path` on from where `follow` ended, or whole when there is no `follow` or it no longer
/// fits the file. None: the transcript cannot be read (`follow` is then dropped).
pub fn read(follow: &mut Option<Follow>, family: &'static str, path: &Path) -> Option<Read> {
    let Some((mut file, id, len)) = open(path) else {
        *follow = None;
        return None;
    };
    if let Some(held) = follow.as_mut().filter(|held| held.fits(family, id, len, &file))
        && let Some(read) = held.tail(&mut file, len)
    {
        return Some(read);
    }
    let (whole, read) = Follow::whole(family, id, &mut file, len)?;
    *follow = Some(whole);
    Some(read)
}

fn open(path: &Path) -> Option<(File, (u64, u64), u64)> {
    let file = File::open(path).ok()?;
    let meta = file.metadata().ok()?;
    meta.is_file().then(|| (file, file_id(&meta), meta.len()))
}

/// A file's device and inode.
#[cfg(unix)]
fn file_id(meta: &std::fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt as _;
    (meta.dev(), meta.ino())
}

/// A file's creation time: a transcript replaced by another file was created later. (Windows'
/// file index needs an unstable API.)
#[cfg(not(unix))]
fn file_id(meta: &std::fs::Metadata) -> (u64, u64) {
    let created = meta.created().ok().and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok());
    created.map_or((0, 0), |at| (at.as_secs(), u64::from(at.subsec_nanos())))
}

impl Follow {
    /// Folds the whole of a `len`-byte file, as the adopt reader does.
    fn whole(
        family: &'static str,
        file_id: (u64, u64),
        file: &mut File,
        len: u64,
    ) -> Option<(Self, Read)> {
        let mut follow = Self {
            family,
            file: file_id,
            offset: len.saturating_sub(MAX_BYTES),
            fold: Fold::new(family, false),
            turns: Window::default(),
            items: Window::default(),
            reads_items: false,
            marks: VecDeque::new(),
            guard: 0,
            bytes_read: 0,
        };
        // A bigger transcript is read from its newest MAX_BYTES; the line the cut falls in is
        // skipped.
        let skip_first = len > MAX_BYTES;
        follow.fold_lines(file, len, skip_first).ok()?;
        follow.turns.trim(len);
        follow.items.trim(len);
        follow.reads_items = follow.turns.starts.is_empty();
        let turns = follow.window_turns(follow.window().first);
        let first = u32::try_from(follow.window().first).unwrap_or(u32::MAX);
        follow.fold.settle(1);
        follow.guard = guard(file, follow.offset).ok()?;
        Some((follow, Read::Whole { first, turns }))
    }

    /// Whether the last read still describes this file: the same one, not shorter, a line still
    /// ends where the last read stopped, and its first and last bytes before there are unchanged
    /// (a rewrite in place keeps the inode and can keep every line end).
    fn fits(&self, family: &str, id: (u64, u64), len: u64, mut file: &File) -> bool {
        let mut last = [0_u8; 1];
        self.family == family
            && self.file == id
            && self.offset <= len
            && (self.offset == 0
                || file.seek(SeekFrom::Start(self.offset - 1)).is_ok()
                    && file.read_exact(&mut last).is_ok()
                    && last[0] == b'\n')
            && guard(file, self.offset).is_ok_and(|hash| hash == self.guard)
    }

    /// Folds what was appended since the last read. None: the transcript is read whole, as the
    /// turns moved between Codex's event messages and its items, or a plain Codex prompt folded as
    /// a turn now has no annotated line between the cut and it (a whole read, starting at the cut,
    /// folds it as an item).
    fn tail(&mut self, file: &mut File, len: u64) -> Option<Read> {
        let open = self.fold_seen().saturating_sub(1);
        self.fold_lines(file, len, false).ok()?;
        self.turns.trim(len);
        self.items.trim(len);
        if self.turns.starts.is_empty() != self.reads_items {
            return None;
        }
        if len > MAX_BYTES {
            let cut = len - MAX_BYTES;
            while self.marks.front().is_some_and(|&(start, _)| start <= cut) {
                self.marks.pop_front();
            }
        }
        if self.marks.front().is_some_and(|&(_, kind)| kind == ItemLine::PlainPrompt) {
            return None;
        }
        // The open turn comes again whole: it is held unless more than the window came since
        // (`fold_lines` settles), and then every turn before the held ones is out of the window.
        let from = open.max(self.fold.held(self.reads_items).0);
        let read = Read::Tail {
            from: u32::try_from(from).unwrap_or(u32::MAX),
            first: u32::try_from(self.window().first).unwrap_or(u32::MAX),
            turns: self.window_turns(from),
        };
        self.fold.settle(1);
        self.guard = guard(file, self.offset).ok()?;
        Some(read)
    }

    /// Folds every complete line from `offset` to `len`, noting where each turn starts; a
    /// trailing partial line (still being written) waits for the next read.
    fn fold_lines(&mut self, file: &mut File, len: u64, skip_first: bool) -> std::io::Result<()> {
        file.seek(SeekFrom::Start(self.offset))?;
        let mut reader = BufReader::new((&*file).take(len.saturating_sub(self.offset)));
        let mut line = Vec::new();
        let mut skip = skip_first;
        loop {
            line.clear();
            let n = reader.read_until(b'\n', &mut line)?;
            self.bytes_read += n as u64;
            if n == 0 || line.last() != Some(&b'\n') {
                return Ok(());
            }
            let start = self.offset;
            self.offset += n as u64;
            if std::mem::take(&mut skip) {
                continue;
            }
            let (turns, items) = (self.fold.turns_seen(), self.fold.items_seen());
            self.fold.line(&line);
            match (self.fold.last_line(), self.marks.back_mut()) {
                (ItemLine::Other, _) => {}
                (kind, Some((at, back))) if *back == kind => *at = start,
                (kind, _) => self.marks.push_back((start, kind)),
            }
            for _ in turns..self.fold.turns_seen() {
                self.turns.push(start);
            }
            for _ in items..self.fold.items_seen() {
                self.items.push(start);
            }
            // Only the window's turns are ever wanted: a long first read holds no more.
            if self.fold.held_len() > 2 * MAX_TURNS {
                self.fold.settle(MAX_TURNS);
            }
        }
    }

    fn window(&self) -> &Window {
        if self.reads_items { &self.items } else { &self.turns }
    }

    fn fold_seen(&self) -> usize {
        if self.reads_items { self.fold.items_seen() } else { self.fold.turns_seen() }
    }

    /// The held turns numbered `from` on, as `super::transcript_turns` gives them.
    fn window_turns(&self, from: usize) -> Vec<Turn> {
        let (first, held) = self.fold.held(self.reads_items);
        held.iter().skip(from.saturating_sub(first)).cloned().map(super::turn_of).collect()
    }
}

/// A hash of the first and the last [`GUARD_BYTES`] of `file` before `end`.
fn guard(mut file: &File, end: u64) -> std::io::Result<u64> {
    use std::hash::{Hash as _, Hasher as _};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    let tail = end.saturating_sub(GUARD_BYTES);
    for (from, to) in [(0, end.min(GUARD_BYTES)), (tail.max(GUARD_BYTES.min(end)), end)] {
        let mut bytes = vec![0; usize::try_from(to.saturating_sub(from)).unwrap_or(0)];
        file.seek(SeekFrom::Start(from))?;
        file.read_exact(&mut bytes)?;
        bytes.hash(&mut hasher);
    }
    Ok(hasher.finish())
}
