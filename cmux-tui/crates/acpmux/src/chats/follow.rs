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

use crate::adopt_replay::{Fold, MAX_BYTES, MAX_TURNS};

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
    /// Where the Codex line that made items the turns ([`Fold::current`]) starts.
    current_at: Option<u64>,
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
            current_at: None,
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
        Some((follow, Read::Whole { first, turns }))
    }

    /// Whether the last read still describes this file: the same one, not shorter, and a line
    /// still ends where the last read stopped.
    fn fits(&self, family: &str, id: (u64, u64), len: u64, mut file: &File) -> bool {
        let mut last = [0_u8; 1];
        self.family == family
            && self.file == id
            && self.offset <= len
            && (self.offset == 0
                || file.seek(SeekFrom::Start(self.offset - 1)).is_ok()
                    && file.read_exact(&mut last).is_ok()
                    && last[0] == b'\n')
    }

    /// Folds what was appended since the last read. None: the transcript is read whole, as the
    /// turns moved between Codex's event messages and its items, or the Codex line that made
    /// items the turns left the newest [`MAX_BYTES`] with an item after it folded by it (a whole
    /// read, starting past that line, folds such an item as an item).
    fn tail(&mut self, file: &mut File, len: u64) -> Option<Read> {
        let open = self.fold_seen().saturating_sub(1);
        self.fold_lines(file, len, false).ok()?;
        self.turns.trim(len);
        self.items.trim(len);
        if self.turns.starts.is_empty() != self.reads_items {
            return None;
        }
        let cut = len.checked_sub(MAX_BYTES);
        if self.fold.plain_after_current()
            && self.current_at.zip(cut).is_some_and(|(at, cut)| at <= cut)
        {
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
            let current = self.fold.current();
            self.fold.line(&line);
            if !current && self.fold.current() {
                self.current_at = Some(start);
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
