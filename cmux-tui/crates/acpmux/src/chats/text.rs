//! What was said in every chat, held for the chats page's search (`_acpmux/chats_window` with
//! `content: true`; dealbreakers D4): a person finds a chat by a word from its prompts or answers,
//! not only by its title, within a keystroke.
//!
//! `_acpmux/chats_search` reads each chat's transcript per query: seconds over a large history.
//! This index reads each chat's turns once, with the reader `_acpmux/chat_transcript` uses
//! ([`super::transcript_turns`]), keeps their prompts and answers as one text per chat with where
//! each message starts, and reads a chat again only when the chat index says it changed (its
//! `updatedMs` or message count). A query is then one pass over text in memory (ASCII words
//! through a case-blind Aho-Corasick search, any other word as [`Needle::find`] reads it), and its
//! answer is kept until the text changes, so a window that recomputes for an activity change does
//! not search again. Words match as `_acpmux/chats_search`'s do: every word, any case and order,
//! within one message; the hit is the chat's newest such message.
//!
//! A Claude Code or Codex chat is followed (`follow.rs`): after its first read, a change reads only
//! the lines appended since and edits the chat's text from its newest turn on, so a change costs
//! the same in a 1 GB chat as in a small one.
//!
//! Bounded: a chat holds its newest messages up to [`CHAT_BYTES`], and the index holds chats
//! newest first up to [`TOTAL_BYTES`]; an older chat past that is not held, so its words do not
//! find it. One pass over [`TOTAL_BYTES`] stays within a keystroke (`search_bench` prints p95
//! over 2,000 chats).
//!
//! Kept current by one thread the chat service owns ([`super::ChatService::start`]): after the
//! daemon starts it fills the index newest chat first, telling windows every [`BATCH`] chats so
//! matches arrive as they are read, then reads the changed chats after each index change. It ends
//! when the service is dropped (the change channel closes). The text is user data, as the
//! transcripts it is read from: it is saved only to `chat-index/text-v2.bin` (0600), at most every
//! [`SAVE_EVERY`], so a restart does not read every transcript again; chats turned off empty it.
//!
//! Served from the saved copy (`text_map.rs`): a chat's text read back, or just saved, is a range
//! of a read-only mapping of that file, not a heap copy, so the daemon's own memory does not hold
//! the text of chats that did not change (goal ram-baseline). A chat's text is copied to the heap
//! only when the chat changes, and served from the file again after the next save. An older
//! build's `chat-index/text-v1.json` is read once, then removed after the first save.
//!
//! At the bound a pass costs what it does below it: an older chat let go of to make room is not a
//! reason to write the saved copy (only a chat gone from the chat index is: its text leaves the
//! disk at once), so the copy is rewritten at most every [`SAVE_EVERY`] however fast newer chats
//! grow; and the first chat past the bound is remembered with its size, so a pass does not read
//! its transcript again only to let it go once more. A save after chats were let go of logs how
//! many and their bytes.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use aho_corasick::{AhoCorasick, Input};
use cmux_chat_index::transcript::Turn;
use cmux_chat_index::{ChatEntry, IndexedChat};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::follow::{self, Follow};
use super::key_text;
use super::search::{Needle, flatten, snippet_around};

#[path = "text_map.rs"]
mod map;
use map::Text;

/// The most text one chat holds: its newest messages up to this many bytes.
pub const CHAT_BYTES: usize = 256 * 1024;
/// The most text the index holds: chats newest first up to this many bytes.
pub const TOTAL_BYTES: usize = 128 * 1024 * 1024;
/// While filling, windows hear of new text after every this many chats read.
const BATCH: usize = 64;
/// The saved copy is written at most this often while chats change.
const SAVE_EVERY: Duration = Duration::from_secs(600);
/// A row's snippet: at most this many characters, this many of them before the first word.
const ROW_SNIPPET: usize = 96;
const ROW_BEFORE: usize = 24;
const SCHEMA: u32 = 2;
/// Schema 1's docs read as schema 2's: their turns are the transcript's, no message out of the window.
const SCHEMA_V1: u32 = 1;
/// The largest saved copy read back: the most text a run holds, with room for JSON's escapes.
const SAVED_BYTES: u64 = 2 * TOTAL_BYTES as u64;

/// When a chat's text was read: the chat index's time and message count for it then.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Stamp {
    updated_ms: i64,
    messages: Option<u64>,
}

impl Stamp {
    fn of(entry: &ChatEntry) -> Self {
        Self { updated_ms: entry.updated_ms, messages: entry.message_count }
    }
}

/// One message: where it starts in its chat's text, its turn (among every turn the chat's reader
/// numbered, [`Doc::first_turn`] the transcript's first), and whether it is the answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Message {
    start: u32,
    turn: u32,
    answer: bool,
}

/// One chat's text: its messages oldest first, each flattened (one space for every whitespace
/// run) and ended by a newline, so no word runs across two messages.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Doc {
    stamp: Stamp,
    text: Text,
    messages: Vec<Message>,
    /// The number of `_acpmux/chat_transcript`'s first turn: a message's turn there is its `turn`
    /// less this.
    #[serde(default)]
    first_turn: u32,
    /// Messages before this one are of turns out of the transcript's window: never found, and let
    /// go of when the text passes its bound ([`Doc::bound`]).
    #[serde(default)]
    live: u32,
    /// The text holds a letter that lowercases to ASCII (`İ`, the Kelvin sign): the ASCII
    /// case-blind pass would miss what `Needle` finds there, so this doc takes `Needle`'s.
    #[serde(skip)]
    folds_to_ascii: bool,
}

impl Doc {
    #[cfg(test)]
    fn new(stamp: Stamp, turns: &[Turn]) -> Self {
        Self::of_turns(stamp, turns, 0)
    }

    /// The doc of `turns`, numbered from `first_turn`: their newest messages up to [`CHAT_BYTES`].
    fn of_turns(stamp: Stamp, turns: &[Turn], first_turn: u32) -> Self {
        let mut newest_first: Vec<(u32, bool, String)> = Vec::new();
        let mut bytes = 0_usize;
        'turns: for (turn, t) in turns.iter().enumerate().rev() {
            for (answer, text) in [(true, &t.answer), (false, &t.prompt)] {
                let flat = flatten(text);
                if flat.is_empty() {
                    continue;
                }
                bytes = bytes.saturating_add(flat.len() + 1);
                let turn = u32::try_from(turn).unwrap_or(u32::MAX).saturating_add(first_turn);
                if bytes > CHAT_BYTES {
                    // A newest message past the bound alone (a pasted log) keeps its newest
                    // text, so its chat is still found.
                    if newest_first.is_empty() {
                        let tail = newest_tail(&flat, CHAT_BYTES.saturating_sub(1)).to_owned();
                        bytes = tail.len().saturating_add(1);
                        newest_first.push((turn, answer, tail));
                    }
                    break 'turns;
                }
                newest_first.push((turn, answer, flat));
            }
        }
        let mut text = String::with_capacity(bytes);
        let mut messages = Vec::new();
        for (turn, answer, flat) in newest_first.into_iter().rev() {
            let start = u32::try_from(text.len()).unwrap_or(u32::MAX);
            messages.push(Message { start, turn, answer });
            text.push_str(&flat);
            text.push('\n');
        }
        let mut doc =
            Self { stamp, text: text.into(), messages, first_turn, live: 0, folds_to_ascii: false };
        doc.read_folds();
        doc
    }

    fn read_folds(&mut self) {
        self.folds_to_ascii = folds_to_ascii(&self.text);
    }

    /// A transcript's index stamp may move when its metadata changes even though the searchable
    /// text did not. Such a stamp update must not make the saved copy rewrite every held chat.
    fn same_content(&self, other: &Self) -> bool {
        self.text == other.text
            && self.messages == other.messages
            && self.first_turn == other.first_turn
            && self.live == other.live
            && self.folds_to_ascii == other.folds_to_ascii
    }

    /// Turn `turn` and every one after it are replaced by `turns` (numbered from `turn`), the
    /// window starts at turn `first`, and the text is held to its bound. Costs what the replaced
    /// and added text does, not what the chat holds.
    fn edit(&mut self, turn: u32, turns: &[Turn], first: u32) {
        let cut = self.messages.partition_point(|m| m.turn < turn);
        // A text served from the saved copy is copied only when it changes.
        if let Some(m) = self.messages.get(cut) {
            self.text.to_mut().truncate(m.start as usize);
        }
        self.messages.truncate(cut);
        for (number, t) in (turn..).zip(turns) {
            for (answer, text) in [(false, &t.prompt), (true, &t.answer)] {
                let flat = flatten(text);
                if flat.is_empty() {
                    continue;
                }
                // A text that lost a folding letter keeps the flag: `Needle`'s pass finds all.
                self.folds_to_ascii = self.folds_to_ascii || folds_to_ascii(&flat);
                let start = u32::try_from(self.text.len()).unwrap_or(u32::MAX);
                self.messages.push(Message { start, turn: number, answer });
                let text = self.text.to_mut();
                text.push_str(&flat);
                text.push('\n');
            }
        }
        self.first_turn = first;
        let live = self.messages.partition_point(|m| m.turn < first);
        self.live = u32::try_from(live).unwrap_or(u32::MAX);
        self.bound();
    }

    /// Past [`CHAT_BYTES`], lets go of the messages out of the window, then of the oldest others
    /// until the newest fit: the messages [`Self::of_turns`] keeps. Moves at most [`CHAT_BYTES`],
    /// however long the chat.
    fn bound(&mut self) {
        let len = self.text.len();
        if len <= CHAT_BYTES {
            return;
        }
        let fits = self.messages.partition_point(|m| len - m.start as usize > CHAT_BYTES);
        let mut keep = fits.max(self.live as usize);
        let mut cut = self.messages.get(keep).map_or(len, |m| m.start as usize);
        // The newest message past the bound alone keeps its newest text, as `of_turns` keeps it.
        if keep == self.messages.len() && self.messages.len() > self.live as usize {
            keep = self.messages.len().saturating_sub(1);
            cut = len.saturating_sub(newest_tail(&self.text, CHAT_BYTES).len());
        }
        self.text.to_mut().drain(..cut);
        self.messages.drain(..keep);
        let cut = u32::try_from(cut).unwrap_or(u32::MAX);
        if let Some(first) = self.messages.first_mut() {
            first.start = first.start.max(cut);
        }
        for message in &mut self.messages {
            message.start -= cut;
        }
        self.live = 0;
    }

    /// Where the window's first message starts.
    fn live_start(&self) -> usize {
        self.messages.get(self.live as usize).map_or(self.text.len(), |m| m.start as usize)
    }

    /// Whether a doc read back holds its bound and its messages start in its text, in order, each on
    /// a character boundary.
    fn is_sound(&self) -> bool {
        self.text.len() <= CHAT_BYTES
            && self.live as usize <= self.messages.len()
            && self.messages.iter().skip(self.live as usize).all(|m| m.turn >= self.first_turn)
            && self.messages.windows(2).all(|pair| matches!(pair, [a, b] if a.start < b.start))
            && self.messages.iter().all(|m| {
                self.text.is_char_boundary(m.start as usize) && (m.start as usize) < self.text.len()
            })
    }

    /// Message `i`'s byte range in `text`, its newline left out.
    fn bounds(&self, i: usize) -> (usize, usize) {
        let start = self.messages.get(i).map_or(self.text.len(), |m| m.start as usize);
        let end = self.messages.get(i + 1).map_or(self.text.len(), |m| m.start as usize);
        (start, end.saturating_sub(1).max(start))
    }

    fn message(&self, i: usize) -> &str {
        let (start, end) = self.bounds(i);
        self.text.get(start..end).unwrap_or_default()
    }

    /// The newest message that holds every word, and how many messages do.
    fn find(&self, needle: &Needle, matcher: &Matcher) -> Option<Matched> {
        let mut found: Option<Matched> = None;
        let mut hit = |i: usize| {
            let message = u32::try_from(i).unwrap_or(u32::MAX);
            let matches = found.map_or(0, |f| f.matches).saturating_add(1);
            found = Some(Matched { message, matches });
        };
        let ascii = matcher.ascii.as_deref().filter(|_| !self.folds_to_ascii);
        let Some((first, rest)) = ascii.and_then(<[_]>::split_first) else {
            (self.live as usize..self.messages.len())
                .filter(|&i| needle.find(self.message(i)).is_some())
                .for_each(hit);
            return found;
        };
        let mut from = self.live_start();
        if from >= self.text.len() {
            return None;
        }
        while let Some(m) = first.find(Input::new(self.text.as_str()).range(from..)) {
            let i = self
                .messages
                .partition_point(|msg| msg.start as usize <= m.start())
                .saturating_sub(1);
            let (start, end) = self.bounds(i);
            let text = self.text.get(start..end).unwrap_or_default();
            if rest.iter().all(|word| word.is_match(text)) {
                hit(i);
            }
            // The next match is in a later message.
            from = end.max(m.end());
            if from >= self.text.len() {
                break;
            }
        }
        found
    }
}

/// Fewer held bytes than this are searched on the calling thread: below it, starting threads
/// costs about what the pass does.
const PAR_MIN_BYTES: usize = 4 * 1024 * 1024;
/// The most threads one pass takes.
const PAR_MAX_THREADS: usize = 8;
/// Docs a thread claims at a time: small enough that one thread left with the largest docs does
/// not hold the pass up, large enough that the shared counter is not contended.
const PAR_CHUNK: usize = 16;

/// `f` over every doc, on up to [`PAR_MAX_THREADS`] threads when they hold at least
/// [`PAR_MIN_BYTES`] of text: a query's first key reads all held text (up to [`TOTAL_BYTES`]),
/// one core's pass over which is most of a keystroke's time. Threads claim [`PAR_CHUNK`] docs
/// at a time, so a few large docs do not leave the rest idle. The order of the results is not
/// the docs' order (the caller collects them into a map).
fn par_filter_map<R: Send>(
    docs: &[(&String, &Arc<Doc>)],
    f: impl Fn(&(&String, &Arc<Doc>)) -> Option<R> + Sync,
) -> Vec<R> {
    let bytes: usize = docs.iter().map(|(_, doc)| doc.text.len()).sum();
    let threads = std::thread::available_parallelism()
        .map_or(1, std::num::NonZeroUsize::get)
        .min(PAR_MAX_THREADS)
        .min(docs.len().div_ceil(PAR_CHUNK));
    if threads <= 1 || bytes < PAR_MIN_BYTES {
        return docs.iter().filter_map(&f).collect();
    }
    let next = std::sync::atomic::AtomicUsize::new(0);
    let work = || {
        let mut out = Vec::new();
        loop {
            let from = next.fetch_add(PAR_CHUNK, std::sync::atomic::Ordering::Relaxed);
            let Some(chunk) = docs.get(from..(from + PAR_CHUNK).min(docs.len())) else {
                break;
            };
            if chunk.is_empty() {
                break;
            }
            out.extend(chunk.iter().filter_map(&f));
        }
        out
    };
    std::thread::scope(|scope| {
        let helpers: Vec<_> = (1..threads).map(|_| scope.spawn(work)).collect();
        let mut out = work();
        for helper in helpers {
            // A panicking `f` panics the caller, as the one-thread pass would.
            out.extend(helper.join().unwrap_or_else(|panic| std::panic::resume_unwind(panic)));
        }
        out
    })
}

/// At most the last `max` bytes of `text`, cut on a character boundary.
fn newest_tail(text: &str, max: usize) -> &str {
    let start = (text.len().saturating_sub(max)..=text.len())
        .find(|&at| text.is_char_boundary(at))
        .unwrap_or(text.len());
    text.get(start..).unwrap_or_default()
}

/// Whether `text` holds a letter that lowercases to ASCII (`İ`, the Kelvin sign).
fn folds_to_ascii(text: &str) -> bool {
    !text.is_ascii()
        && text.chars().any(|c| !c.is_ascii() && c.to_lowercase().any(|l| l.is_ascii()))
}

/// The words of a query as one pass looks for them: when every word is ASCII, one case-blind
/// searcher per word, longest first (the rarest likely, so the first pass stops least).
struct Matcher {
    ascii: Option<Vec<AhoCorasick>>,
}

impl Matcher {
    fn new(needle: &Needle) -> Self {
        let mut words: Vec<&String> = needle.words().iter().collect();
        if !words.iter().all(|word| word.is_ascii()) {
            return Self { ascii: None };
        }
        words.sort_by_key(|word| std::cmp::Reverse(word.len()));
        let ascii = words
            .into_iter()
            .map(|word| AhoCorasick::builder().ascii_case_insensitive(true).build([word.as_str()]))
            .collect::<Result<Vec<_>, _>>()
            .ok();
        Self { ascii }
    }
}

/// What a query found in one chat's text: its newest message holding every word, and how many do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Matched {
    message: u32,
    matches: u32,
}

/// What a query found in one chat: the text it searched (so the row's snippet is cut from the same
/// text, however the chat changed since) and what it found there.
#[derive(Clone, Debug)]
pub struct Found {
    doc: Arc<Doc>,
    matched: Matched,
}

/// Every chat's text, and the last query's answer.
pub struct ChatText {
    inner: Mutex<Inner>,
    /// The followed transcripts by chat key (`follow.rs`): only the text thread reads them.
    follows: Mutex<HashMap<String, Follow>>,
    /// The generation of the text: a window recomputes when it moves.
    changed: tokio::sync::watch::Sender<u64>,
    path: PathBuf,
    /// An older build's saved copy (JSON, the text held on the heap): read when there is no copy
    /// at `path`, and removed after the first save.
    legacy: Option<PathBuf>,
    /// The most text held: [`TOTAL_BYTES`] (tests hold less).
    total: usize,
}

#[derive(Default)]
struct Inner {
    docs: HashMap<String, Arc<Doc>>,
    generation: u64,
    /// The last query's words and the generation it was answered at.
    answer: Option<(Vec<String>, u64, Arc<HashMap<String, Found>>)>,
    /// The text changed since it was saved.
    dirty: bool,
    /// Every chat was read once since the daemon started (a query before then may find more later).
    filled: bool,
    saved_at: Option<Instant>,
    /// The first chat past the bound at the last pass, the stamp it was read at and its text's
    /// bytes: while it is unchanged and still does not fit, it is not read again.
    edge: Option<(String, Stamp, usize)>,
    /// Chats let go of to hold the bound since the last save, and their bytes (logged then).
    evicted: (usize, usize),
    /// How many saves were written and their bytes (tests count a pass's writes with it).
    #[cfg(test)]
    saves: (usize, usize),
    /// How many docs searches read (tests count a query's work with it).
    #[cfg(test)]
    scanned: usize,
}

/// The saved copy's metadata as it is written (`text_map.rs`): every held doc but its text,
/// borrowed, and where its text is among the texts after it.
#[derive(Serialize)]
struct Saved<'a> {
    schema: u32,
    docs: Vec<SavedDoc<'a>>,
}

#[derive(Serialize)]
struct SavedDoc<'a> {
    key: &'a str,
    stamp: Stamp,
    messages: &'a [Message],
    first_turn: u32,
    live: u32,
    at: u64,
    len: u32,
}

/// The saved copy's metadata as it is read back.
#[derive(Deserialize)]
struct Meta {
    schema: u32,
    docs: Vec<MetaDoc>,
}

#[derive(Deserialize)]
struct MetaDoc {
    key: String,
    stamp: Stamp,
    messages: Vec<Message>,
    first_turn: u32,
    live: u32,
    at: u64,
    len: u32,
}

/// An older build's saved copy (`text-v1.json`) as it is read back.
#[derive(Deserialize)]
struct Loaded {
    schema: u32,
    docs: Vec<(String, Doc)>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl ChatText {
    /// An empty index saved at `path`; [`Self::load`] reads what an earlier run saved.
    pub fn new(path: PathBuf) -> Self {
        Self {
            inner: Mutex::default(),
            follows: Mutex::default(),
            changed: tokio::sync::watch::channel(0).0,
            path,
            legacy: None,
            total: TOTAL_BYTES,
        }
    }

    /// [`Self::new`], reading an older build's JSON copy at `legacy` when `path` holds none.
    pub fn with_legacy(path: PathBuf, legacy: PathBuf) -> Self {
        Self { legacy: Some(legacy), ..Self::new(path) }
    }

    /// [`Self::new`] holding at most `total` bytes of text, so a test reaches the bound quickly.
    #[cfg(test)]
    pub(crate) fn with_total(path: PathBuf, total: usize) -> Self {
        Self { total: total.min(TOTAL_BYTES), ..Self::new(path) }
    }

    /// Takes the text an earlier run saved; a missing, damaged or older copy is read past.
    pub fn load(&self) {
        // Not from a lost home (`config::mark_home_lost`): the copy there may be another daemon's.
        if crate::config::refuse_lost_home(&self.path).is_err() {
            return;
        }
        let (docs, mapped) = match self.read_mapped() {
            Some(docs) => (docs, true),
            None => match self.read_legacy() {
                Some(docs) => (docs, false),
                None => return,
            },
        };
        // A doc another build wrote, or a damaged one, is left out: each holds its own bound, and
        // every message starts inside its text, in order.
        let mut room = self.total;
        let docs = docs
            .into_iter()
            .filter(|(_, doc)| doc.is_sound())
            .take_while(|(_, doc)| {
                room.checked_sub(doc.text.len()).map(|left| room = left).is_some()
            })
            .map(|(key, mut doc)| {
                doc.read_folds();
                (key, Arc::new(doc))
            })
            .collect();
        let mut inner = lock(&self.inner);
        inner.docs = docs;
        self.publish(&mut inner);
        // An older build's copy is written anew at the first pass, then served from there.
        if mapped {
            inner.saved_at = Some(Instant::now());
            inner.dirty = false;
        }
    }

    /// The docs of the saved copy at `path`, their texts served from it. A copy past what a run
    /// can hold is not read at all: the memory bound holds from the first byte.
    fn read_mapped(&self) -> Option<Vec<(String, Doc)>> {
        let (map, meta, texts) = open_saved(&self.path)?;
        let docs = meta.docs.into_iter().filter_map(|doc| {
            let text = map.text(texts, doc.at, doc.len)?;
            let MetaDoc { key, stamp, messages, first_turn, live, .. } = doc;
            Some((key, Doc { stamp, text, messages, first_turn, live, folds_to_ascii: false }))
        });
        Some(docs.collect())
    }

    /// The docs of an older build's JSON copy, held on the heap until they are saved anew.
    fn read_legacy(&self) -> Option<Vec<(String, Doc)>> {
        // A copy past what a run can hold (with room for JSON's escapes) is not read at all.
        let path = self.legacy.as_deref()?;
        crate::config::refuse_lost_home(path)
            .ok()
            .filter(|()| std::fs::metadata(path).is_ok_and(|m| m.len() <= SAVED_BYTES))
            .and_then(|()| std::fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice::<Loaded>(&bytes).ok())
            .filter(|saved| saved.schema == SCHEMA || saved.schema == SCHEMA_V1)
            .map(|saved| saved.docs)
    }

    /// Serves each doc just saved that is still held as it was (the same `Arc`) from the saved
    /// copy, its text there checked to read the same: its heap copy, or its range of an older
    /// copy, is let go of. The comparison runs outside the lock; the swap holds it only to
    /// replace each doc.
    fn serve_saved(&self, held: &[(String, Arc<Doc>)]) {
        let Some((map, meta, texts)) = open_saved(&self.path) else { return };
        let served: Vec<(&String, &Arc<Doc>, Text)> = held
            .iter()
            .zip(&meta.docs)
            .filter(|((key, _), saved)| *key == saved.key)
            .filter_map(|((key, doc), saved)| {
                let text = map.text(texts, saved.at, saved.len)?;
                (text == doc.text).then_some((key, doc, text))
            })
            .collect();
        if served.is_empty() {
            return;
        }
        let mut inner = lock(&self.inner);
        for (key, was, text) in served {
            let Some(doc) = inner.docs.get_mut(key).filter(|doc| Arc::ptr_eq(doc, was)) else {
                continue;
            };
            *doc = Arc::new(Doc { text, messages: was.messages.clone(), ..**was });
        }
        // The kept answer holds the docs it found: its copies are let go of with it. The text
        // reads the same, so the generation does not move.
        inner.answer = None;
        drop(inner);
        drop(map);
        acpmux_core::memory::release_free_pages();
    }

    /// Moves when the text changes.
    pub fn subscribe(&self) -> tokio::sync::watch::Receiver<u64> {
        self.changed.subscribe()
    }

    fn publish(&self, inner: &mut Inner) {
        inner.generation = inner.generation.wrapping_add(1);
        inner.answer = None;
        inner.dirty = true;
        self.changed.send_replace(inner.generation);
    }

    /// Brings the text up to `chats` (newest first, as the chat index orders them): reads each
    /// chat whose text is missing or older than its entry with `read` (None: unreadable, not
    /// held), up to [`TOTAL_BYTES`], and drops every chat not among them. Blocking; the lock is
    /// never held across a read.
    pub fn update(&self, chats: &[IndexedChat], read: &dyn Fn(&ChatEntry) -> Option<Vec<Turn>>) {
        self.update_with(chats, read, false);
    }

    /// [`Self::update`], with each Claude Code and Codex chat followed (`follow.rs`): read whole
    /// once, then from where its last read ended.
    pub fn follow(&self, chats: &[IndexedChat], read: &dyn Fn(&ChatEntry) -> Option<Vec<Turn>>) {
        self.update_with(chats, read, true);
    }

    fn update_with(
        &self,
        chats: &[IndexedChat],
        read: &dyn Fn(&ChatEntry) -> Option<Vec<Turn>>,
        following: bool,
    ) {
        let mut room = self.total;
        let mut kept: HashSet<String> = HashSet::new();
        let mut read_since_publish = 0_usize;
        for chat in chats {
            let key = key_text(&chat.entry.key());
            let stamp = Stamp::of(&chat.entry);
            let (held, has_doc, edge) = {
                let inner = lock(&self.inner);
                let doc = inner.docs.get(&key);
                let edge = inner
                    .edge
                    .as_ref()
                    .filter(|(edge, at, _)| *edge == key && *at == stamp)
                    .map(|(_, _, bytes)| *bytes);
                (
                    doc.filter(|doc| doc.stamp == stamp).map(|doc| doc.text.len()),
                    doc.is_some(),
                    edge,
                )
            };
            // The chat that did not fit last pass, unchanged since: while it still does not fit it
            // is not read, only to be let go of again.
            if !has_doc && edge.is_some_and(|bytes| bytes > room) {
                break;
            }
            let bytes = match held {
                Some(bytes) => bytes,
                None => {
                    let family = follow::family(chat.entry.harness).filter(|_| following);
                    let Some(edit) = (match family {
                        Some(family) => self.follow_one(&key, family, &chat.entry, has_doc),
                        None => {
                            read(&chat.entry).map(|turns| follow::Read::Whole { first: 0, turns })
                        }
                    }) else {
                        continue;
                    };
                    let mut inner = lock(&self.inner);
                    let (bytes, changed) = match edit {
                        follow::Read::Whole { first, turns } => {
                            let mut doc = Doc::of_turns(stamp, &turns, first);
                            let bytes = doc.text.len();
                            if bytes > room {
                                inner.edge = Some((key, stamp, bytes));
                                break;
                            }
                            let same = inner.docs.get(&key).filter(|old| old.same_content(&doc));
                            let changed = same.is_none();
                            // Unchanged: still served from the saved copy, not the read's copy.
                            if let Some(old) = same.filter(|old| old.text.is_mapped()) {
                                doc.text = old.text.clone();
                            }
                            inner.docs.insert(key.clone(), Arc::new(doc));
                            (bytes, changed)
                        }
                        follow::Read::Tail { from, first, turns } => {
                            // Edited in place: the kept search answer is let go of first, so it
                            // holds no copy of the doc and the edit copies nothing (a search
                            // still running elsewhere keeps its own copy).
                            let (bytes, changed) = {
                                let Some(doc) = inner.docs.get_mut(&key) else { continue };
                                let doc = Arc::make_mut(doc);
                                let before = doc.clone();
                                doc.stamp = stamp;
                                doc.edit(from, &turns, first);
                                (doc.text.len(), !before.same_content(doc))
                            };
                            if changed {
                                inner.answer = None;
                            }
                            (bytes, changed)
                        }
                    };
                    if changed {
                        read_since_publish += 1;
                        if read_since_publish >= BATCH {
                            self.publish(&mut inner);
                            read_since_publish = 0;
                        }
                    }
                    bytes
                }
            };
            if bytes > room {
                lock(&self.inner).edge = Some((key, stamp, bytes));
                break;
            }
            room -= bytes;
            kept.insert(key);
        }
        lock(&self.follows).retain(|key, _| kept.contains(key));
        let mut inner = lock(&self.inner);
        // A chat let go of is either gone from the chat index (deleted, its root removed, chats
        // off) or still listed but past the bound, older than every chat held.
        let listed: HashSet<String> = if inner.docs.keys().any(|key| !kept.contains(key)) {
            chats.iter().map(|chat| key_text(&chat.entry.key())).collect()
        } else {
            HashSet::new()
        };
        let (mut gone, mut evicted) = (false, (0_usize, 0_usize));
        inner.docs.retain(|key, doc| {
            if kept.contains(key) {
                return true;
            }
            if listed.contains(key) {
                evicted = (evicted.0 + 1, evicted.1 + doc.text.len());
            } else {
                gone = true;
            }
            false
        });
        inner.evicted = (inner.evicted.0 + evicted.0, inner.evicted.1 + evicted.1);
        let initial_fill = !inner.filled;
        let was_dirty = inner.dirty;
        let content_changed = read_since_publish > 0 || gone || evicted.0 > 0;
        if content_changed || initial_fill {
            inner.filled = true;
            self.publish(&mut inner);
            if !content_changed {
                inner.dirty = was_dirty;
            }
        }
        // A chat gone leaves the saved copy at once, not at the next timed save: its text is not
        // kept on disk past it. A chat let go of for room is still listed and its transcript still
        // on disk: it waits for the timed save, so at the bound the copy is rewritten at most every
        // [`SAVE_EVERY`], however fast newer chats grow.
        let due = gone || inner.saved_at.is_none_or(|at| at.elapsed() >= SAVE_EVERY);
        if !(inner.dirty && due) {
            return;
        }
        inner.dirty = false;
        inner.saved_at = Some(Instant::now());
        let evicted = std::mem::take(&mut inner.evicted);
        // The docs are shared, not copied: the lock is let go before the write.
        let held: Vec<(String, Arc<Doc>)> =
            inner.docs.iter().map(|(key, doc)| (key.clone(), doc.clone())).collect();
        drop(inner);
        let held_bytes: usize = held.iter().map(|(_, doc)| doc.text.len()).sum();
        match save(&self.path, &held) {
            Ok(written) => {
                self.serve_saved(&held);
                if let Some(legacy) = &self.legacy
                    && crate::config::refuse_lost_home(legacy).is_ok()
                    && crate::home_fs::exists_nofollow(legacy)
                {
                    let _ = crate::home_fs::remove_file(legacy);
                }
                #[cfg(test)]
                {
                    let mut inner = lock(&self.inner);
                    inner.saves = (inner.saves.0 + 1, inner.saves.1 + written);
                }
                if evicted.0 > 0 {
                    tracing::info!(
                        evicted_chats = evicted.0,
                        evicted_bytes = evicted.1,
                        held_chats = held.len(),
                        held_bytes,
                        written_bytes = written,
                        "chat text: at its bound; the oldest chats were let go of since the last save"
                    );
                }
            }
            Err(error) => tracing::warn!(%error, "chat text: not saved"),
        }
    }

    /// Reads a followed chat on from its last read (whole when there is none, or no doc to edit).
    /// None: unreadable, not held.
    fn follow_one(
        &self,
        key: &str,
        family: &'static str,
        entry: &ChatEntry,
        has_doc: bool,
    ) -> Option<follow::Read> {
        let mut held = lock(&self.follows).remove(key).filter(|_| has_doc);
        let read = follow::read(&mut held, family, &entry.source_path);
        if let Some(held) = held {
            lock(&self.follows).insert(key.to_owned(), held);
        }
        read
    }

    /// The bytes read from a followed chat's transcript since it was first followed.
    #[cfg(test)]
    pub(crate) fn follow_bytes(&self, key: &str) -> Option<u64> {
        lock(&self.follows).get(key).map(|held| held.bytes_read)
    }

    /// Every held chat whose messages hold every word of `needle`, by chat key. The answer is
    /// kept until the text changes: the same query again is not searched again, and a query that
    /// narrows the last one (each of its words inside one of the new words, as a key typed onto the
    /// query makes it) searches only the chats the last one found. Any text change moves the
    /// generation, so a narrowed search never reads an answer older than the text.
    pub fn search(&self, needle: &Needle) -> Arc<HashMap<String, Found>> {
        let mut inner = lock(&self.inner);
        let now = inner.generation;
        let last = inner.answer.as_ref().filter(|(_, generation, _)| *generation == now);
        if let Some((words, _, found)) = last
            && words.as_slice() == needle.words()
        {
            return found.clone();
        }
        // A message holding every new word holds every old word inside one of them, under either
        // pass (`Doc::find`): the new hits are among the old.
        let narrowed = last
            .filter(|(words, _, _)| {
                words.iter().all(|old| needle.words().iter().any(|new| new.contains(old.as_str())))
            })
            .map(|(_, _, found)| found.clone());
        let matcher = Matcher::new(needle);
        let search = |key: &String, doc: &Arc<Doc>| {
            let matched = doc.find(needle, &matcher)?;
            Some((key.clone(), Found { doc: doc.clone(), matched }))
        };
        let docs: Vec<(&String, &Arc<Doc>)> = match &narrowed {
            Some(last) => last.iter().map(|(key, found)| (key, &found.doc)).collect(),
            None => inner.docs.iter().collect(),
        };
        let found: HashMap<String, Found> =
            par_filter_map(&docs, |&(key, doc)| search(key, doc)).into_iter().collect();
        #[cfg(test)]
        {
            inner.scanned += narrowed.as_ref().map_or(inner.docs.len(), |last| last.len());
        }
        let found = Arc::new(found);
        inner.answer = Some((needle.words().to_vec(), inner.generation, found.clone()));
        found
    }

    /// A row's `match` for what `needle` found in a chat: `{turn, role, snippet,
    /// highlights, matches}`. `turn` indexes `_acpmux/chat_transcript`'s turns, `role` is
    /// `prompt` or `answer`, and `highlights` are the snippet's characters (Unicode scalars) that
    /// are part of a word, as the palette draws a row's matched characters.
    pub fn hit(found: &Found, needle: &Needle) -> Option<Value> {
        let (doc, i) = (&found.doc, found.matched.message as usize);
        let message = doc.messages.get(i)?;
        let text = doc.message(i);
        let snippet = snippet_around(text, needle.find(text).unwrap_or(0), ROW_BEFORE, ROW_SNIPPET);
        Some(json!({
            "turn": message.turn.saturating_sub(doc.first_turn),
            "role": if message.answer { "answer" } else { "prompt" },
            "highlights": needle.highlights(&snippet),
            "snippet": snippet,
            "matches": found.matched.matches,
        }))
    }

    /// Every chat was read once since the daemon started: a query's content matches are complete
    /// (before then, more may come as the chats are read).
    pub fn filled(&self) -> bool {
        lock(&self.inner).filled
    }

    /// How many saves were written and how many bytes they wrote.
    #[cfg(test)]
    pub(crate) fn saves(&self) -> (usize, usize) {
        lock(&self.inner).saves
    }

    /// How many docs searches have read so far.
    #[cfg(test)]
    pub(crate) fn scanned(&self) -> usize {
        lock(&self.inner).scanned
    }

    /// How many chats and bytes of text are held.
    pub fn held(&self) -> (usize, usize) {
        let inner = lock(&self.inner);
        (inner.docs.len(), inner.docs.values().map(|doc| doc.text.len()).sum())
    }
}

/// Not under a lost home (`config::mark_home_lost`), as the chat index saves its own cache: the
/// home there may be another daemon's now, and the text is user data. Under a held home the
/// write goes through the folder this daemon locked (`home_fs`), not its path, so a home replaced
/// after the check passed never gets the text: it lands in the folder that was moved away, or
/// nowhere. Whole or not at all: a synced temporary copy renamed over the file. The bytes written.
fn save(path: &Path, held: &[(String, Arc<Doc>)]) -> anyhow::Result<usize> {
    let checked = crate::config::refuse_lost_home(path);
    if let Some(hook) = SAVE_CHECKED.get() {
        hook(checked.is_ok());
    }
    checked?;
    let mut at = 0_u64;
    let docs = held
        .iter()
        .map(|(key, doc)| {
            // A doc's text holds its bound ([`CHAT_BYTES`]), so its length fits.
            let len = u32::try_from(doc.text.len()).unwrap_or(u32::MAX);
            let saved = SavedDoc {
                key,
                stamp: doc.stamp,
                messages: &doc.messages,
                first_turn: doc.first_turn,
                live: doc.live,
                at,
                len,
            };
            at += u64::from(len);
            saved
        })
        .collect();
    let texts = held.iter().map(|(_, doc)| doc.text.as_str());
    let text_bytes = usize::try_from(at).unwrap_or(usize::MAX);
    let bytes = map::encode(&Saved { schema: SCHEMA, docs }, texts, text_bytes)?;
    crate::home_fs::write_index_file(path, &bytes)?;
    Ok(bytes.len())
}

/// The saved copy at `path` mapped, with its metadata and where its texts start: None when it is
/// missing, past what a run can hold, of another layout or schema, or under a lost home.
fn open_saved(path: &Path) -> Option<(Arc<map::Map>, Meta, usize)> {
    crate::config::refuse_lost_home(path).ok()?;
    let file = crate::home_fs::OpenOptions::new().read(true).open(path).ok()?;
    map::open::<Meta>(&file, SAVED_BYTES).filter(|(_, meta, _)| meta.schema == SCHEMA)
}

/// Test seam: called on the saving thread between a save's home check and its write, with
/// whether the check passed. `tests/lost_home_writes.rs` holds the text thread's save there
/// while it replaces the home, so the order its race depends on is the test's, not the clock's.
// test-hook-allow: one process per test: only tests/lost_home_writes.rs sets it, once, and its
// isolated() runs each test in a process of its own
#[doc(hidden)]
pub static SAVE_CHECKED: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();

#[cfg(test)]
#[path = "text_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "text_scale_bench_tests.rs"]
mod text_scale_bench;

#[cfg(test)]
#[path = "follow_tests.rs"]
mod follow_tests;
