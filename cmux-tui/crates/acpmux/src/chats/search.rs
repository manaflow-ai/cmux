//! What `_acpmux/chats_search` looks for in a chat's turns (HQ#5333): every word of the query,
//! in any case and order, within one prompt or one answer. The hit is the chat's newest such
//! message, with a snippet of the text around the first word.

use cmux_chat_index::transcript::Turn;
use serde_json::{Value, json};

/// A query longer than this many characters is refused.
pub const MAX_QUERY: usize = 256;
/// A snippet holds at most this many characters of the message (plus an ellipsis on each side).
pub const SNIPPET: usize = 160;
/// How many of the snippet's characters come before the first word, when the text has them.
const BEFORE: usize = 48;

/// The words of a query, lowercased, each once.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Needle {
    words: Vec<String>,
}

impl Needle {
    /// The query's words; an error for a query with none or one past [`MAX_QUERY`].
    pub fn parse(query: &str) -> Result<Self, String> {
        if query.chars().count() > MAX_QUERY {
            return Err(format!("query is longer than {MAX_QUERY} characters"));
        }
        let mut words: Vec<String> = Vec::new();
        for word in query.split_whitespace().map(fold) {
            if !words.contains(&word) {
                words.push(word);
            }
        }
        if words.is_empty() {
            return Err("query has no words; list chats with _acpmux/chats".to_owned());
        }
        Ok(Self { words })
    }

    /// The character index in `text` where the first of the words starts, when `text` holds
    /// them all; None otherwise.
    pub(crate) fn find(&self, text: &str) -> Option<usize> {
        let folded = Folded::new(text);
        let mut first: Option<usize> = None;
        for word in &self.words {
            let at = folded.find(word)?;
            first = Some(first.map_or(at, |f| f.min(at)));
        }
        first
    }

    /// The query's words, lowercased.
    pub(crate) fn words(&self) -> &[String] {
        &self.words
    }

    /// The character indexes in `text` of every character that is part of one of the words, in
    /// order: what a row draws emphasized (the palette's highlight positions count characters).
    pub fn highlights(&self, text: &str) -> Vec<usize> {
        let folded = Folded::new(text);
        let mut at = Vec::new();
        for word in &self.words {
            for (start, matched) in folded.text.match_indices(word.as_str()) {
                let bytes = folded.origin.get(start..start + matched.len()).unwrap_or_default();
                at.extend_from_slice(bytes);
            }
        }
        at.sort_unstable();
        at.dedup();
        at
    }
}

/// `word` folded as [`Folded`] folds the text it is looked for in.
fn fold(word: &str) -> String {
    word.chars().flat_map(fold_char).collect()
}

/// A character's lowercase, with a final sigma (`ς`) as `σ`: `Σ` lowers to `σ` alone and to `ς`
/// at a word's end (`str::to_lowercase`), so `ΟΣ`, `ος` and `οσ` all find each other.
fn fold_char(c: char) -> impl Iterator<Item = char> {
    c.to_lowercase().map(|lower| if lower == 'ς' { 'σ' } else { lower })
}

/// `text` lowercased, with the character index in `text` of each of its bytes, since lowercasing
/// may change a character's length.
struct Folded {
    text: String,
    origin: Vec<usize>,
}

impl Folded {
    fn new(text: &str) -> Self {
        let mut folded = String::with_capacity(text.len());
        let mut origin = Vec::with_capacity(text.len());
        for (i, c) in text.chars().enumerate() {
            for lower in fold_char(c) {
                folded.push(lower);
                origin.extend(std::iter::repeat_n(i, lower.len_utf8()));
            }
        }
        Self { text: folded, origin }
    }

    fn find(&self, word: &str) -> Option<usize> {
        self.text.find(word).and_then(|at| self.origin.get(at).copied())
    }
}

/// A chat's newest message that holds every word.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hit {
    /// The turn's index in the chat's turns, oldest first (`_acpmux/chat_transcript`'s `turns`).
    pub turn: usize,
    /// `prompt` or `answer`.
    pub role: &'static str,
    pub snippet: String,
    /// How many of the chat's prompts and answers hold every word.
    pub matches: usize,
}

impl Hit {
    pub fn to_value(&self, chat: Value) -> Value {
        json!({
            "chat": chat,
            "turn": self.turn,
            "role": self.role,
            "snippet": self.snippet,
            "matches": self.matches,
        })
    }
}

/// The newest message of `turns` that holds every word of `needle`.
pub fn find(needle: &Needle, turns: &[Turn]) -> Option<Hit> {
    let mut hit: Option<Hit> = None;
    let mut matches = 0_usize;
    for (turn, t) in turns.iter().enumerate() {
        for (role, text) in [("prompt", &t.prompt), ("answer", &t.answer)] {
            let flat = flatten(text);
            let Some(at) = needle.find(&flat) else { continue };
            matches = matches.saturating_add(1);
            // A later message is newer: the last one found is the hit.
            hit = Some(Hit { turn, role, snippet: snippet(&flat, at), matches: 0 });
        }
    }
    hit.map(|hit| Hit { matches, ..hit })
}

/// `text` with every run of whitespace one space.
pub(crate) fn flatten(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// At most [`SNIPPET`] characters of `text` around character `at`, with an ellipsis on a side
/// where text was left out.
pub(crate) fn snippet(text: &str, at: usize) -> String {
    snippet_around(text, at, BEFORE, SNIPPET)
}

/// At most `size` characters of `text` around character `at`, `before` of them before it when
/// the text has them, with an ellipsis on a side where text was left out.
pub(crate) fn snippet_around(text: &str, at: usize, before: usize, size: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    let mut start = at.saturating_sub(before);
    let end = len.min(start.saturating_add(size));
    // Near the end, the snippet holds more of what comes before.
    start = start.min(end.saturating_sub(size));
    let mut out = String::new();
    if start > 0 {
        out.push('…');
    }
    out.extend(chars.get(start..end).unwrap_or_default());
    if end < len {
        out.push('…');
    }
    out
}

#[cfg(test)]
mod tests;
