//! What was said in a chat past what [`super::text::ChatText`] holds of it: a chats window's
//! content search also asks the transcript index (`crate::transcript_search`, every Claude Code
//! and Codex transcript whole), so an old message in a huge chat finds its chat (Leo, 2026-11-18:
//! "shouldn't you be able to like have better tools for finding stuff?"). `text.rs` holds a chat's
//! newest [`super::text::CHAT_BYTES`] only.
//!
//! A query's answer is read off the window's path, on one thread of its own: a window asks
//! ([`Deep::answer`]) and gets what is held for the query (none at first) and whether a newer
//! answer is coming, which keeps the window `filling`. When it comes, the chat text's change
//! channel moves and every window recomputes, as when chats are read. Only the newest query asked
//! is read (a person typing asks one per key), and the last [`KEEP`] answers are held for
//! [`FRESH`]: a window recomputed for an activity change asks the index nothing.
//!
//! The index finds a doc holding each word of three or more characters (its trigrams serve those
//! only; a shorter word would read every doc), anywhere in one prompt or answer.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use acpmux_transcript_search as ts;
use cmux_chat_index::{AdapterKind, ChatKey};

use super::key_text;

/// The answers held, newest asked first.
const KEEP: usize = 8;
/// An answer this old is read again when asked (the one held is used meanwhile).
const FRESH: Duration = Duration::from_secs(30);
/// The matching docs one search reads at most (`ts::Index::chats`).
pub const SCAN: usize = 20_000;
/// The text the index cuts around a hit, which the row's snippet is cut from.
pub const CONTEXT: usize = 160;

/// One chat's newest prompt or answer holding the query's words, as the transcript index has it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeepHit {
    pub at_ms: Option<i64>,
    /// `_acpmux/chat_transcript`'s turn: the index's (1 for the first prompt) less one.
    pub turn: u32,
    pub answer: bool,
    /// The text around the first word, as written.
    pub text: String,
    /// The message goes on before or after `text`.
    pub cut_before: bool,
    pub cut_after: bool,
    /// How many of the chat's messages the search read hold the words.
    pub matches: u32,
}

/// What one query found, by chat key.
pub type Found = Arc<HashMap<String, DeepHit>>;

/// Reads the index for a query's words (None: it could not be read).
pub type Search = Box<dyn Fn(&[String]) -> Option<Vec<(ts::Hit, u32)>> + Send + Sync>;

/// The words of `words` the index can serve, longest first; none: the index is not asked.
pub fn indexable(words: &[String]) -> Vec<String> {
    let mut out: Vec<String> = words.iter().filter(|w| w.chars().count() >= 3).cloned().collect();
    out.sort_by_key(|w| std::cmp::Reverse(w.len()));
    out
}

/// A search's hits by chat key: each session's newest message, a harness the chat index keys
/// as that transcript's.
pub fn by_chat(hits: Vec<(ts::Hit, u32)>) -> HashMap<String, DeepHit> {
    let mut out = HashMap::new();
    for (hit, matches) in hits {
        let harness = match hit.harness {
            ts::Harness::Claude => AdapterKind::ClaudeCode,
            ts::Harness::Codex => AdapterKind::Codex,
        };
        let key = key_text(&ChatKey { harness, session_id: hit.session.clone() });
        out.entry(key).or_insert(DeepHit {
            at_ms: hit.at_ms,
            turn: hit.turn.saturating_sub(1),
            answer: hit.role != ts::Role::User,
            text: hit.snippet,
            cut_before: hit.cut_before,
            cut_after: hit.cut_after,
            matches,
        });
    }
    out
}

struct Shared {
    state: Mutex<State>,
    wake: Condvar,
    search: OnceLock<Search>,
    /// Moved when an answer comes: the chat text's change channel, which windows follow.
    changed: Arc<tokio::sync::watch::Sender<u64>>,
}

#[derive(Default)]
struct State {
    answers: VecDeque<(Vec<String>, Instant, Found)>,
    wanted: Option<Vec<String>>,
    running: Option<Vec<String>>,
    worker: bool,
    closed: bool,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The transcript index's answers to the chats windows' content queries.
pub struct Deep {
    shared: Arc<Shared>,
}

impl Deep {
    /// Asks nothing until [`Self::set_search`] gives it the index.
    pub fn new(changed: Arc<tokio::sync::watch::Sender<u64>>) -> Self {
        Self {
            shared: Arc::new(Shared {
                state: Mutex::default(),
                wake: Condvar::new(),
                search: OnceLock::new(),
                changed,
            }),
        }
    }

    /// How a query reads the index; the first one given stays.
    pub fn set_search(&self, search: Search) {
        let _ = self.shared.search.set(search);
    }

    /// What is held for `words` (their indexable words, [`indexable`]), and whether a newer
    /// answer is coming (the window is still `filling`). Never waits for the index.
    pub fn answer(&self, words: &[String]) -> (Option<Found>, bool) {
        if self.shared.search.get().is_none() || words.is_empty() {
            return (None, false);
        }
        let mut state = lock(&self.shared.state);
        let held = state.answers.iter().find(|a| a.0 == words).map(|a| (a.1, a.2.clone()));
        if let Some((at, found)) = &held
            && at.elapsed() < FRESH
        {
            return (Some(found.clone()), false);
        }
        if state.running.as_deref() != Some(words) {
            state.wanted = Some(words.to_vec());
            self.shared.wake.notify_one();
        }
        if !state.worker {
            let shared = self.shared.clone();
            // task-owner: the chat text; ends when it is dropped (`Drop for Deep`).
            let started = std::thread::Builder::new()
                .name("acpmux-chat-deep".into())
                .spawn(move || work(&shared));
            match started {
                Ok(_) => state.worker = true,
                Err(error) => {
                    tracing::warn!(%error, "chat deep search: thread not started");
                    return (held.map(|h| h.1), false);
                }
            }
        }
        (held.map(|h| h.1), true)
    }
}

impl Drop for Deep {
    fn drop(&mut self) {
        lock(&self.shared.state).closed = true;
        self.shared.wake.notify_all();
    }
}

/// The thread: reads the newest wanted query, holds its answer, tells the windows; again.
fn work(shared: &Shared) {
    loop {
        let words = {
            let mut state = lock(&shared.state);
            loop {
                if state.closed {
                    return;
                }
                if let Some(words) = state.wanted.take() {
                    state.running = Some(words.clone());
                    break words;
                }
                state = shared.wake.wait(state).unwrap_or_else(|poisoned| poisoned.into_inner());
            }
        };
        let found = shared.search.get().and_then(|search| search(&words)).unwrap_or_default();
        let found: Found = Arc::new(by_chat(found));
        {
            let mut state = lock(&shared.state);
            state.answers.retain(|a| a.0 != words);
            state.answers.push_front((words, Instant::now(), found));
            state.answers.truncate(KEEP);
            state.running = None;
        }
        shared.changed.send_modify(|_| {});
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hit(session: &str, role: ts::Role, at: i64) -> ts::Hit {
        ts::Hit {
            session: session.into(),
            harness: ts::Harness::Claude,
            path: format!("/p/{session}.jsonl").into(),
            subagent: false,
            turn: 3,
            line: 9,
            at_ms: Some(at),
            role,
            snippet: "the old words".into(),
            match_start: 4,
            match_len: 3,
            cut_before: false,
            cut_after: false,
            message_id: None,
            matches: 1,
            in_window: false,
        }
    }

    #[test]
    fn only_words_of_three_or_more_characters_ask_the_index() {
        let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert_eq!(indexable(&words(&["ui", "parser", "bug"])), words(&["parser", "bug"]));
        assert!(indexable(&words(&["a", "is"])).is_empty());
    }

    #[test]
    fn hits_are_keyed_as_the_chat_index_keys_chats() {
        let found = by_chat(vec![
            (hit("s1", ts::Role::Assistant, 5), 4),
            (hit("s2", ts::Role::User, 3), 1),
        ]);
        let s1 = &found["claude-code:s1"];
        assert_eq!((s1.at_ms, s1.turn, s1.answer, s1.matches), (Some(5), 2, true, 4));
        assert!(!found["claude-code:s2"].answer);
    }

    /// A window's ask never waits: the first answers nothing and says more is coming; once the
    /// thread has read the index the windows hear of it and the next ask has the answer.
    #[test]
    fn an_answer_comes_off_the_windows_path_and_is_kept() {
        let changed = Arc::new(tokio::sync::watch::channel(0_u64).0);
        let mut moved = changed.subscribe();
        let deep = Deep::new(changed.clone());
        let words = vec!["parser".to_owned()];
        assert_eq!(deep.answer(&words), (None, false), "no index: nothing asked");
        let asked = Arc::new(Mutex::new(0_usize));
        let count = asked.clone();
        deep.set_search(Box::new(move |words| {
            *lock(&count) += 1;
            assert_eq!(words, ["parser".to_owned()]);
            Some(vec![(hit("s1", ts::Role::User, 7), 1)])
        }));
        let (first, coming) = deep.answer(&words);
        assert!(first.is_none() && coming);
        let runtime = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
        runtime.block_on(async {
            tokio::time::timeout(Duration::from_secs(10), moved.changed()).await.unwrap().unwrap();
        });
        let (found, coming) = deep.answer(&words);
        assert!(!coming);
        assert_eq!(found.unwrap()["claude-code:s1"].at_ms, Some(7));
        assert_eq!(*lock(&asked), 1, "a fresh answer is not read again");
    }
}
