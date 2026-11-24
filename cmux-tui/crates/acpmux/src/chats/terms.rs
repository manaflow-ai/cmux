//! The operators a chat search's text may hold (ask-b75ea23533: Leo 2026-11-18, "some people don't
//! necessarily want to be looking through the entirety of the universe just to find some little
//! thing. Like recency is usually what's desired"), as an editor's or a notes app's search takes them:
//!
//! - `since:7d`, `since:today`, `since:2026-11-01` (`after:` too): chats used then or later. A
//!   span is a number and `m` (minutes), `h`, `d`, `w`, `mo` or `y`; `today` and `yesterday` and a
//!   date start at local midnight.
//! - `before:…` (`until:` too): chats last used before then.
//! - `harness:codex` (`agent:` too): one harness, by its id or the start of one (`claude`).
//! - `in:cmux` (`folder:`, `path:` too): the chat's folder holds the text.
//! - `title:sidebar`: the title holds the text.
//! - `-word`: neither the title nor the folder holds it.
//! - `"two words"`: the words together, as one word.
//!
//! The rest are the words searched as before. A word that looks like an operator but is not one
//! (`http://x`, `since:soon`) is a plain word, so a query never fails on its syntax.

use chrono::{Duration, Local, NaiveDate, TimeZone};
use cmux_chat_index::AdapterKind;

/// What a query's text says, operators taken out. Every text is lowercased.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Terms {
    /// The plain words, in order, each once (a quoted phrase is one).
    pub words: Vec<String>,
    /// `-word`: the title and the folder hold none of these.
    pub exclude: Vec<String>,
    /// `title:`: the title holds every one.
    pub title: Vec<String>,
    /// `in:`: the folder holds every one.
    pub folder: Vec<String>,
    pub harness: Option<AdapterKind>,
    /// `since:`: used at or after this time (ms since the epoch).
    pub since_ms: Option<i64>,
    /// `before:`: last used before this time.
    pub before_ms: Option<i64>,
}

impl Terms {
    /// `text`'s terms, relative times counted back from `now_ms`.
    pub fn parse(text: &str, now_ms: i64) -> Self {
        let mut terms = Self::default();
        for token in tokens(text) {
            if !terms.operator(&token, now_ms) {
                push(&mut terms.words, token.text);
            }
        }
        terms
    }

    /// The plain words as one query again (a phrase quoted): what a ranker or a transcript search
    /// reads. Empty when the text was only operators.
    pub fn rest(&self) -> String {
        let quote = |word: &String| {
            if word.contains(char::is_whitespace) { format!("\"{word}\"") } else { word.clone() }
        };
        self.words.iter().map(quote).collect::<Vec<_>>().join(" ")
    }

    /// Whether any operator narrowed the query.
    pub fn has_operators(&self) -> bool {
        !self.exclude.is_empty()
            || !self.title.is_empty()
            || !self.folder.is_empty()
            || self.harness.is_some()
            || self.since_ms.is_some()
            || self.before_ms.is_some()
    }

    /// Takes `token` as an operator; false when it is a plain word.
    fn operator(&mut self, token: &Token, now_ms: i64) -> bool {
        if !token.quoted
            && let Some(word) = token.text.strip_prefix('-')
            && !word.is_empty()
            && !word.starts_with('-')
        {
            push(&mut self.exclude, word.to_owned());
            return true;
        }
        let Some((key, value)) = token.key_value() else { return false };
        match key {
            "since" | "after" => time(value, now_ms).map(|at| self.since_ms = Some(at)).is_some(),
            "before" | "until" => time(value, now_ms).map(|at| self.before_ms = Some(at)).is_some(),
            "harness" | "agent" => harness(value).map(|h| self.harness = Some(h)).is_some(),
            "in" | "folder" | "path" => {
                push(&mut self.folder, value.trim_end_matches('/').to_owned());
                true
            }
            "title" => {
                push(&mut self.title, value.to_owned());
                true
            }
            _ => false,
        }
    }
}

fn push(list: &mut Vec<String>, word: String) {
    if !word.is_empty() && !list.contains(&word) {
        list.push(word);
    }
}

/// One whitespace-separated piece of the text, lowercased; a `"…"` run is one piece, quotes off.
#[derive(Debug)]
struct Token {
    text: String,
    /// The whole piece was quoted: never an operator.
    quoted: bool,
}

impl Token {
    /// `key:value` with a known-looking key and a value (`title:"two words"` keeps its space).
    fn key_value(&self) -> Option<(&str, &str)> {
        if self.quoted {
            return None;
        }
        let (key, value) = self.text.split_once(':')?;
        (!key.is_empty() && !value.is_empty() && key.chars().all(|c| c.is_ascii_alphabetic()))
            .then_some((key, value))
    }
}

fn tokens(text: &str) -> Vec<Token> {
    let mut out = Vec::new();
    let mut current = String::new();
    let (mut in_quote, mut quoted, mut any_quote) = (false, true, false);
    let mut flush = |current: &mut String, quoted: bool, any_quote: bool| {
        if !current.is_empty() {
            out.push(Token { text: current.to_lowercase(), quoted: quoted && any_quote });
        }
        current.clear();
    };
    for c in text.chars() {
        if c == '"' {
            if !in_quote && !current.is_empty() {
                // `title:"…"`: the quote opens the value, the piece is still an operator.
                quoted = false;
            }
            in_quote = !in_quote;
            any_quote = true;
        } else if c.is_whitespace() && !in_quote {
            flush(&mut current, quoted, any_quote);
            (quoted, any_quote) = (true, false);
        } else {
            current.push(c);
        }
    }
    flush(&mut current, quoted, any_quote);
    out
}

/// A time in `since:`/`before:` as ms since the epoch: `7d`, `today`, `yesterday`, `2026-11-01`.
fn time(value: &str, now_ms: i64) -> Option<i64> {
    // Where a clock change skips midnight (DST starting at 00:00), the day starts at 01:00.
    let midnight = |date: NaiveDate| {
        [0, 1].into_iter().find_map(|hour| {
            Local
                .from_local_datetime(&date.and_hms_opt(hour, 0, 0)?)
                .earliest()
                .map(|t| t.timestamp_millis())
        })
    };
    let today = || Local.timestamp_millis_opt(now_ms).single().map(|t| t.date_naive());
    match value {
        "today" => return midnight(today()?),
        "yesterday" => return midnight(today()?.pred_opt()?),
        _ => {}
    }
    if let Ok(date) = NaiveDate::parse_from_str(value, "%Y-%m-%d") {
        return midnight(date);
    }
    let digits = value.find(|c: char| !c.is_ascii_digit())?;
    let (count, unit) = value.split_at(digits);
    let count: i64 = count.parse().ok()?;
    let span = match unit {
        "m" | "min" => Duration::try_minutes(count)?,
        "h" => Duration::try_hours(count)?,
        "d" => Duration::try_days(count)?,
        "w" => Duration::try_weeks(count)?,
        "mo" => Duration::try_days(count.checked_mul(30)?)?,
        "y" => Duration::try_days(count.checked_mul(365)?)?,
        _ => return None,
    };
    now_ms.checked_sub(span.num_milliseconds())
}

/// The harness a `harness:` value names: its id, or the one id that starts with it.
fn harness(value: &str) -> Option<AdapterKind> {
    if let Some(kind) = AdapterKind::from_id(value) {
        return Some(kind);
    }
    let mut starts = AdapterKind::ALL.into_iter().filter(|kind| kind.id().starts_with(value));
    let first = starts.next()?;
    starts.next().is_none().then_some(first)
}

#[cfg(test)]
#[path = "terms_tests.rs"]
mod tests;
