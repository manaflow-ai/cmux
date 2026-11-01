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
    fn find(&self, text: &str) -> Option<usize> {
        let folded = Folded::new(text);
        let mut first: Option<usize> = None;
        for word in &self.words {
            let at = folded.find(word)?;
            first = Some(first.map_or(at, |f| f.min(at)));
        }
        first
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
fn flatten(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// At most [`SNIPPET`] characters of `text` around character `at`, with an ellipsis on a side
/// where text was left out.
fn snippet(text: &str, at: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    let mut start = at.saturating_sub(BEFORE);
    let end = len.min(start.saturating_add(SNIPPET));
    // Near the end, the snippet holds more of what comes before.
    start = start.min(end.saturating_sub(SNIPPET));
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
mod tests {
    use super::*;

    fn turn(prompt: &str, answer: &str) -> Turn {
        Turn { prompt: prompt.into(), answer: answer.into(), prompt_at: None, answer_at: None }
    }

    #[test]
    fn every_word_in_one_message_in_any_case_and_order() {
        let turns = [turn("Fix the Sidebar", "The row is NaN."), turn("thanks", "ok")];
        let needle = Needle::parse("nan ROW").expect("words");
        let hit = find(&needle, &turns).expect("hit");
        assert_eq!((hit.turn, hit.role, hit.matches), (0, "answer", 1));
        assert_eq!(hit.snippet, "The row is NaN.");
        // Words split between a prompt and its answer are no match.
        assert_eq!(find(&Needle::parse("sidebar nan").expect("words"), &turns), None);
    }

    #[test]
    fn the_newest_message_is_the_hit_and_every_one_counts() {
        let turns = [turn("deploy it", "deployed"), turn("deploy again", "no")];
        let hit = find(&Needle::parse("deploy").expect("words"), &turns).expect("hit");
        assert_eq!((hit.turn, hit.role, hit.matches), (1, "prompt", 3));
    }

    #[test]
    fn a_word_is_lowered_as_the_text_is() {
        // A final capital sigma: `str::to_lowercase` gives `ς` in a word's last place, `σ` alone.
        for (query, text) in [("ΟΣ", "ΟΣ"), ("ΟΣ", "ος"), ("ος", "ΟΣ"), ("οσ", "ος")]
        {
            let hit = find(&Needle::parse(query).expect("words"), &[turn(text, "")]);
            assert_eq!(hit.map(|hit| hit.snippet), Some(text.to_owned()), "{query} in {text}");
        }
    }

    #[test]
    fn a_query_with_no_words_or_too_long_is_refused() {
        assert!(Needle::parse(" \n\t").is_err());
        assert!(Needle::parse(&"x".repeat(MAX_QUERY + 1)).is_err());
        assert_eq!(Needle::parse("a A a").expect("words").words, ["a"]);
    }

    #[test]
    fn a_long_message_gives_the_text_around_the_word() {
        let text = format!("{} needle {}", "a ".repeat(100), "b ".repeat(100));
        let hit = find(&Needle::parse("needle").expect("words"), &[turn(&text, "")]).expect("hit");
        assert!(hit.snippet.starts_with('…') && hit.snippet.ends_with('…'), "{}", hit.snippet);
        assert_eq!(hit.snippet.chars().count(), SNIPPET + 2);
        let at = hit.snippet.find("needle").expect("word in snippet");
        assert_eq!(hit.snippet[..at].chars().count(), BEFORE + 1);
        // Near the end, the snippet holds what comes before instead.
        let text = format!("{} needle", "a ".repeat(200));
        let hit = find(&Needle::parse("needle").expect("words"), &[turn(&text, "")]).expect("hit");
        assert!(hit.snippet.starts_with('…') && hit.snippet.ends_with("needle"), "{}", hit.snippet);
        assert_eq!(hit.snippet.chars().count(), SNIPPET + 1);
    }

    #[test]
    fn whitespace_runs_are_one_space_and_a_case_change_that_grows_text_keeps_its_place() {
        let hit = find(&Needle::parse("b").expect("words"), &[turn("a\n\n  b", "")]).expect("hit");
        assert_eq!(hit.snippet, "a b");
        // 'İ' lowercases to two characters: the word after it is still found where it is.
        let text = format!("{}İ needle {}", "İ".repeat(60), "b ".repeat(100));
        let hit = find(&Needle::parse("needle").expect("words"), &[turn(&text, "")]).expect("hit");
        let at = hit.snippet.find("needle").expect("word in snippet");
        assert_eq!(hit.snippet[..at].chars().count(), BEFORE + 1, "{}", hit.snippet);
    }
}
