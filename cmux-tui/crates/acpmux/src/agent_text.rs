//! Whether text reads as another agent's output: a handoff, receipt or status report the person
//! pasted, with no sender format around it (ask-fa4c523fa8). Deterministic signals only, the
//! formats agents write and people don't: a `From NAME:` header, a `Trace-ID:` line, a
//! generated-with or co-author footer, an agent session line, a review receipt, a batched
//! message's `[message N of M] from` line or a `Handoff` heading. Nothing here changes the text:
//! the agent's view adds its marks around it (`hub/prompt_attribution.rs`), and the record names
//! it beside the text (`hub/session.rs` `prompt_text_parts`).
//!
//! The cost stays flat: only the first [`HEAD_BYTES`] and last [`TAIL_BYTES`] of a text are read,
//! so a pasted log of megabytes costs what a page does.

use std::sync::LazyLock;

use regex::Regex;

/// The bytes read from the start of a text: headers sit there.
pub const HEAD_BYTES: usize = 16 * 1024;
/// The bytes read from its end: footers sit there.
pub const TAIL_BYTES: usize = 4 * 1024;

/// What the signals found in one text.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Detected {
    /// The sender a header or footer names (`From Codex:`, `Generated with [Codex]`).
    pub from: Option<String>,
    /// Each signal found, as the agent's mark names it (`a "From" header`), at most once each.
    pub signals: Vec<&'static str>,
}

impl Detected {
    /// Whether any signal was found.
    pub fn agent(&self) -> bool {
        !self.signals.is_empty()
    }
}

/// A header naming its sender on a line of its own start: `From Codex:`, `Reply from lane-a:`.
/// Each pattern is None only if it did not compile, which `every_pattern_compiles` would show.
static HEADER: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?i)^\s*(?:\*\*)?(?:from|message from|reply from|handoff from|report from|update from)\s+([A-Za-z][\w .@/()-]{0,47}?)(?:\*\*)?\s*:(?:\*\*)?(?:\s|$)",
    )
    .ok()
});
static TRACE_ID: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)^\s*trace-id:\s*\S+").ok());
static GENERATED: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(r"(?i)generated (?:with|by) \[?([A-Za-z][\w .-]{0,31}?)\]?(?:\(|\s*$)").ok()
});
static CO_AUTHOR: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)^\s*co-authored-by:\s*\S").ok());
static SESSION_LINE: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)^\s*(?:agent session|author-agent|agent-id):\s*\S").ok());
static RECEIPT: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(r"(?i)^\s*(?:review \([^)]{1,80}\)|verdict)\s*:\s*(?:ship|block)\b").ok()
});
static BATCH_LINE: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"^\s*\[message \d+ of \d+\] from (\S.{0,63})$").ok());
static HANDOFF: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)^\s*#{1,4}\s*handoff\b").ok());

/// First words of a `From X:` line a person writes, not a sender's name.
const NOT_NAMES: &[&str] = &[
    "now",
    "here",
    "there",
    "then",
    "today",
    "tomorrow",
    "yesterday",
    "the",
    "my",
    "your",
    "our",
    "this",
    "that",
    "these",
    "those",
    "what",
    "where",
    "me",
    "us",
    "him",
    "her",
    "them",
    "it",
    "a",
    "an",
    "now on",
    "time",
    "experience",
];

/// The signals in `text`, reading only its head and tail.
pub fn detect(text: &str) -> Detected {
    let mut found = Detected::default();
    let (head, tail) = window(text);
    for line in head.lines().chain(tail.into_iter().flat_map(str::lines)) {
        scan(line, &mut found);
    }
    found
}

/// `text`'s first `HEAD_BYTES` and, when longer, its last `TAIL_BYTES`, each cut at a character
/// boundary (and the tail at its next line, so no line is read in part).
fn window(text: &str) -> (&str, Option<&str>) {
    if text.len() <= HEAD_BYTES + TAIL_BYTES {
        return (text, None);
    }
    let mut head = HEAD_BYTES;
    while !text.is_char_boundary(head) {
        head -= 1;
    }
    let mut tail = text.len() - TAIL_BYTES;
    while !text.is_char_boundary(tail) {
        tail += 1;
    }
    // A line cut in part at the tail's start is dropped; one that starts there is whole.
    let whole = text.as_bytes().get(tail.wrapping_sub(1)) == Some(&b'\n');
    let tail = text.get(tail..).unwrap_or_default();
    let tail = if whole { tail } else { tail.split_once('\n').map_or("", |(_, rest)| rest) };
    (text.get(..head).unwrap_or(text), Some(tail))
}

fn scan(line: &str, found: &mut Detected) {
    let mut add = |signal: &'static str| {
        if !found.signals.contains(&signal) {
            found.signals.push(signal);
        }
    };
    if let Some(name) = HEADER.as_ref().and_then(|re| re.captures(line)).and_then(|c| c.get(1)) {
        let name = name.as_str().trim();
        let lower = name.to_lowercase();
        let first = lower.split_whitespace().next().unwrap_or_default();
        if !NOT_NAMES.contains(&first) && !NOT_NAMES.contains(&lower.as_str()) {
            add("a \"From\" header");
            found.from.get_or_insert_with(|| name.to_owned());
        }
    }
    if TRACE_ID.as_ref().is_some_and(|re| re.is_match(line)) {
        add("a Trace-ID line");
    }
    if let Some(name) = GENERATED.as_ref().and_then(|re| re.captures(line)).and_then(|c| c.get(1)) {
        add("a generated-with footer");
        found.from.get_or_insert_with(|| name.as_str().trim().to_owned());
    }
    if CO_AUTHOR.as_ref().is_some_and(|re| re.is_match(line)) {
        add("a co-author line");
    }
    if SESSION_LINE.as_ref().is_some_and(|re| re.is_match(line)) {
        add("an agent session line");
    }
    if RECEIPT.as_ref().is_some_and(|re| re.is_match(line)) {
        add("a review receipt");
    }
    if let Some(name) = BATCH_LINE.as_ref().and_then(|re| re.captures(line)).and_then(|c| c.get(1))
    {
        add("a relayed message line");
        found.from.get_or_insert_with(|| name.as_str().trim().to_owned());
    }
    if HANDOFF.as_ref().is_some_and(|re| re.is_match(line)) {
        add("a handoff heading");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_pattern_compiles() {
        for re in [
            &HEADER,
            &TRACE_ID,
            &GENERATED,
            &CO_AUTHOR,
            &SESSION_LINE,
            &RECEIPT,
            &BATCH_LINE,
            &HANDOFF,
        ] {
            assert!(re.is_some());
        }
    }

    #[test]
    fn a_codex_handoff_reads_as_an_agents() {
        let text = "From Codex:\nHandoff for the lane.\n\nDo not merge or deploy until the probe is \
                    green.\n\nTrace-ID: ask-1234";
        let found = detect(text);
        assert_eq!(found.from.as_deref(), Some("Codex"));
        assert_eq!(found.signals, vec!["a \"From\" header", "a Trace-ID line"]);
    }

    #[test]
    fn a_persons_words_read_as_theirs() {
        for text in [
            "Merge and deploy whenever you want.",
            "From now on: always rebase first.",
            "From the logs: it crashed at 3am",
            "from here, go left",
            "Can you check the trace id of that run?",
            "I generated this with a script",
        ] {
            assert!(!detect(text).agent(), "{text:?} read as an agent's");
        }
    }

    #[test]
    fn footers_and_receipts_name_their_signal() {
        let found =
            detect("Done.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)");
        assert_eq!(found.from.as_deref(), Some("Claude Code"));
        assert!(detect("Review (gpt-5.5): SHIP at abc123").agent());
        assert!(detect("Co-Authored-By: Claude <noreply@anthropic.com>").agent());
        assert!(detect("## Handoff\nnext steps").agent());
        let batch = detect("[message 1 of 2] from lane-a\nhello");
        assert_eq!(batch.from.as_deref(), Some("lane-a"));
    }

    /// Review of #37190 (F3): a footer line that starts exactly where the tail starts is read.
    #[test]
    fn a_tail_that_starts_on_a_line_reads_that_line() {
        let footer = "Trace-ID: ask-1";
        let body = "y".repeat(HEAD_BYTES + 10);
        let pad = "z".repeat(TAIL_BYTES - footer.len() - 1);
        let text = format!("{body}\n{footer}\n{pad}");
        assert_eq!(text.as_bytes()[text.len() - TAIL_BYTES - 1], b'\n');
        assert!(detect(&text).signals.contains(&"a Trace-ID line"));
    }

    #[test]
    fn a_huge_text_reads_its_head_and_tail_only() {
        let text = format!("From Hermes:\n{}\nTrace-ID: x", "y".repeat(10 * 1024 * 1024));
        let found = detect(&text);
        assert_eq!(found.from.as_deref(), Some("Hermes"));
        assert!(found.signals.contains(&"a Trace-ID line"));
    }
}
