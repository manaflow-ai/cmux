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
//! Bounded: a chat holds its newest messages up to [`CHAT_BYTES`], and the index holds chats
//! newest first up to [`TOTAL_BYTES`]; an older chat past that is not held, so its words do not
//! find it. One pass over [`TOTAL_BYTES`] stays within a keystroke (`search_bench` prints p95
//! over 2,000 chats).
//!
//! Kept current by one thread the chat service owns ([`super::ChatService::start`]): after the
//! daemon starts it fills the index newest chat first, telling windows every [`BATCH`] chats so
//! matches arrive as they are read, then reads the changed chats after each index change. It ends
//! when the service is dropped (the change channel closes). The text is user data, as the
//! transcripts it is read from: it is saved only to `chat-index/text-v1.json` (0600), at most every
//! [`SAVE_EVERY`], so a restart does not read every transcript again; chats turned off empty it.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use aho_corasick::{AhoCorasick, Input};
use cmux_chat_index::transcript::Turn;
use cmux_chat_index::{ChatEntry, IndexedChat};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::key_text;
use super::search::{Needle, flatten, snippet_around};

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
const SCHEMA: u32 = 1;
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

/// One message: where it starts in its chat's text, its turn, and whether it is the answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Message {
    start: u32,
    turn: u32,
    answer: bool,
}

/// One chat's text: its messages oldest first, each flattened (one space for every whitespace
/// run) and ended by a newline, so no word runs across two messages.
#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Doc {
    stamp: Stamp,
    text: String,
    messages: Vec<Message>,
    /// The text holds a letter that lowercases to ASCII (`İ`, the Kelvin sign): the ASCII
    /// case-blind pass would miss what `Needle` finds there, so this doc takes `Needle`'s.
    #[serde(skip)]
    folds_to_ascii: bool,
}

impl Doc {
    fn new(stamp: Stamp, turns: &[Turn]) -> Self {
        let mut newest_first: Vec<(u32, bool, String)> = Vec::new();
        let mut bytes = 0_usize;
        'turns: for (turn, t) in turns.iter().enumerate().rev() {
            for (answer, text) in [(true, &t.answer), (false, &t.prompt)] {
                let flat = flatten(text);
                if flat.is_empty() {
                    continue;
                }
                bytes = bytes.saturating_add(flat.len() + 1);
                if bytes > CHAT_BYTES {
                    break 'turns;
                }
                newest_first.push((u32::try_from(turn).unwrap_or(u32::MAX), answer, flat));
            }
        }
        let mut doc = Self {
            stamp,
            text: String::with_capacity(bytes),
            messages: Vec::new(),
            folds_to_ascii: false,
        };
        for (turn, answer, flat) in newest_first.into_iter().rev() {
            let start = u32::try_from(doc.text.len()).unwrap_or(u32::MAX);
            doc.messages.push(Message { start, turn, answer });
            doc.text.push_str(&flat);
            doc.text.push('\n');
        }
        doc.read_folds();
        doc
    }

    fn read_folds(&mut self) {
        self.folds_to_ascii = !self.text.is_ascii()
            && self.text.chars().any(|c| !c.is_ascii() && c.to_lowercase().any(|l| l.is_ascii()));
    }

    /// Whether a doc read back holds its bound and its messages start in its text, in order, each on
    /// a character boundary.
    fn is_sound(&self) -> bool {
        self.text.len() <= CHAT_BYTES
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
            (0..self.messages.len())
                .filter(|&i| needle.find(self.message(i)).is_some())
                .for_each(hit);
            return found;
        };
        let mut from = 0;
        while let Some(m) = first.find(Input::new(&self.text).range(from..)) {
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
    /// The generation of the text: a window recomputes when it moves.
    changed: tokio::sync::watch::Sender<u64>,
    path: PathBuf,
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
    /// How many docs searches read (tests count a query's work with it).
    #[cfg(test)]
    scanned: usize,
}

/// The saved copy as it is written: the held docs, borrowed.
#[derive(Serialize)]
struct Saved<'a> {
    schema: u32,
    docs: Vec<(&'a str, &'a Doc)>,
}

/// The saved copy as it is read back.
#[derive(Deserialize)]
struct Loaded {
    schema: u32,
    docs: Vec<(String, Doc)>,
}

fn lock(mutex: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl ChatText {
    /// An empty index saved at `path`; [`Self::load`] reads what an earlier run saved.
    pub fn new(path: PathBuf) -> Self {
        Self { inner: Mutex::default(), changed: tokio::sync::watch::channel(0).0, path }
    }

    /// Takes the text an earlier run saved; a missing, damaged or older copy is read past.
    pub fn load(&self) {
        // Not from a lost home (`config::mark_home_lost`): the copy there may be another daemon's.
        // A copy past what a run can hold (with room for JSON's escapes) is not read at all: the
        // memory bound holds from the first byte.
        let Some(saved) = crate::config::refuse_lost_home(&self.path)
            .ok()
            .filter(|()| std::fs::metadata(&self.path).is_ok_and(|m| m.len() <= SAVED_BYTES))
            .and_then(|()| std::fs::read(&self.path).ok())
            .and_then(|bytes| serde_json::from_slice::<Loaded>(&bytes).ok())
            .filter(|saved| saved.schema == SCHEMA)
        else {
            return;
        };
        // A doc another build wrote, or a damaged one, is left out: each holds its own bound, and
        // every message starts inside its text, in order.
        let mut room = TOTAL_BYTES;
        let docs = saved
            .docs
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
        inner.saved_at = Some(Instant::now());
        self.publish(&mut inner);
        inner.dirty = false;
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
        let mut room = TOTAL_BYTES;
        let mut kept: HashSet<String> = HashSet::new();
        let mut read_since_publish = 0_usize;
        for chat in chats {
            let key = key_text(&chat.entry.key());
            let stamp = Stamp::of(&chat.entry);
            let held = lock(&self.inner)
                .docs
                .get(&key)
                .filter(|doc| doc.stamp == stamp)
                .map(|doc| doc.text.len());
            let bytes = match held {
                Some(bytes) => bytes,
                None => {
                    let Some(turns) = read(&chat.entry) else { continue };
                    let doc = Doc::new(stamp, &turns);
                    let bytes = doc.text.len();
                    if bytes > room {
                        break;
                    }
                    let mut inner = lock(&self.inner);
                    inner.docs.insert(key.clone(), Arc::new(doc));
                    read_since_publish += 1;
                    if read_since_publish >= BATCH {
                        self.publish(&mut inner);
                        read_since_publish = 0;
                    }
                    bytes
                }
            };
            if bytes > room {
                break;
            }
            room -= bytes;
            kept.insert(key);
        }
        let mut inner = lock(&self.inner);
        let before = inner.docs.len();
        inner.docs.retain(|key, _| kept.contains(key));
        let removed = inner.docs.len() != before;
        if read_since_publish > 0 || removed || !inner.filled {
            inner.filled = true;
            self.publish(&mut inner);
        }
        // A chat gone (deleted, its root removed, chats off) leaves the saved copy at once, not at the
        // next timed save: its text is not kept on disk past it.
        let due = removed || inner.saved_at.is_none_or(|at| at.elapsed() >= SAVE_EVERY);
        if !(inner.dirty && due) {
            return;
        }
        inner.dirty = false;
        inner.saved_at = Some(Instant::now());
        // The docs are shared, not copied: the lock is let go before the write.
        let held: Vec<(String, Arc<Doc>)> =
            inner.docs.iter().map(|(key, doc)| (key.clone(), doc.clone())).collect();
        drop(inner);
        let docs = held.iter().map(|(key, doc)| (key.as_str(), &**doc)).collect();
        if let Err(error) = save(&self.path, &Saved { schema: SCHEMA, docs }) {
            tracing::warn!(%error, "chat text: not saved");
        }
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
        let found: HashMap<String, Found> = match &narrowed {
            Some(last) => last.iter().filter_map(|(key, found)| search(key, &found.doc)).collect(),
            None => inner.docs.iter().filter_map(|(key, doc)| search(key, doc)).collect(),
        };
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
            "turn": message.turn,
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
/// write goes through the folder this daemon locked (`config::held_home_dir`), not its path, so a
/// home replaced after the check passed never gets the text: it lands in the folder that was
/// moved away, or nowhere.
fn save(path: &Path, saved: &Saved) -> anyhow::Result<()> {
    let checked = crate::config::refuse_lost_home(path);
    if let Some(hook) = SAVE_CHECKED.get() {
        hook(checked.is_ok());
    }
    checked?;
    match crate::config::held_home_dir(path) {
        Some((home, relative)) => Ok(home.write(&relative, &serde_json::to_vec(saved)?)?),
        None => Ok(cmux_chat_index::write_json_private(path, saved)?),
    }
}

/// Test seam: called on the saving thread between a save's home check and its write, with
/// whether the check passed. `tests/lost_home_writes.rs` holds the text thread's save there
/// while it replaces the home, so the order its race depends on is the test's, not the clock's.
#[doc(hidden)]
pub static SAVE_CHECKED: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();

#[cfg(test)]
#[path = "text_tests.rs"]
mod tests;
