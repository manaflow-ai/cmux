//! The line rule of a link card (MessagesLab `text_parts`, macOS 27 Messages):
//! a line that is only an http(s) URL (surrounding spaces allowed) becomes a
//! `link_preview` part in its place among the lines; the other lines stay
//! text parts, a URL inside a sentence gets no card, and blank lines around a
//! card make no text part.
//!
//! One addition for the Chief, whose replies are Markdown: a URL line inside
//! a fenced code block (```` ``` ```` or `~~~`) stays code, never a card.

use cmux_conversation::{MAX_PARTS, Part, valid_link_url};

fn is_space(c: char) -> bool {
    c == ' ' || c == '\t' || c == '\u{a0}' || c == '\r'
}

fn is_blank(line: &str) -> bool {
    line.trim_matches(is_space).is_empty()
}

/// The http(s) URL a line consists of (surrounding spaces allowed), else
/// None. Trailing sentence punctuation means the URL ends a sentence (the
/// link detector stops before it), so such a line is text.
pub fn sole_url(line: &str) -> Option<&str> {
    let url = line.trim_matches(is_space);
    let scheme = url.get(..8).unwrap_or(url).to_ascii_lowercase();
    if !(scheme.starts_with("https://") || scheme.starts_with("http://")) {
        return None;
    }
    if url
        .chars()
        .any(|c| c.is_whitespace() || c == '<' || c == '>')
    {
        return None;
    }
    if url.ends_with(['.', ',', ')', '!', '?', ';', ':']) {
        return None;
    }
    valid_link_url(url).then_some(url)
}

/// Whether `line` opens or closes a fenced code block.
fn is_fence(line: &str) -> bool {
    let t = line.trim_start_matches(' ');
    t.starts_with("```") || t.starts_with("~~~")
}

/// `text` as message parts in line order: text blocks and link cards
/// (`link_preview` with the URL only; the sender fills the preview). At
/// most [`MAX_PARTS`] parts: when the cards would make more, the last URL
/// lines stay text. No card at all gives the text unchanged as one part.
pub fn text_parts(text: &str) -> Vec<Part> {
    // Not yet: the line rule.
    vec![Part::Text {
        text: text.to_owned(),
        runs: None,
    }]
}

/// The split with at most `budget` cards, and how many it made.
fn split_with(text: &str, budget: usize) -> (Vec<Part>, usize) {
    let _ = (text, budget, is_fence(""), sole_url(""), MAX_PARTS);
    (Vec::new(), 0)
}
