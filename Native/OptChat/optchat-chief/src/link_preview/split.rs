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

/// The http(s) URLs a person's text holds, as whole tokens: the text split
/// on whitespace, each token stripped of leading brackets or quotes and of
/// trailing sentence punctuation, brackets or quotes (the same ends that keep
/// a line from being a card in [`sole_url`]). A card's URL must equal one of
/// these exactly; a prefix of a longer URL (a shorter query, a shorter host)
/// is not one.
pub fn url_tokens(text: &str) -> impl Iterator<Item = &str> {
    text.split_whitespace().filter_map(|token| {
        let token = token.trim_start_matches(['(', '<', '[', '{', '"', '\'']);
        let token =
            token.trim_end_matches(['.', ',', ')', '!', '?', ';', ':', '>', ']', '}', '"', '\'']);
        let scheme = token.get(..8).unwrap_or(token).to_ascii_lowercase();
        let http = scheme.starts_with("https://") || scheme.starts_with("http://");
        (http && valid_link_url(token)).then_some(token)
    })
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
    text_parts_where(text, |_| true)
}

/// [`text_parts`] where only a URL line that `allow` takes becomes a card;
/// the other URL lines stay text.
pub fn text_parts_where(text: &str, allow: impl Fn(&str) -> bool) -> Vec<Part> {
    let mut budget = MAX_PARTS;
    loop {
        let (parts, cards) = split_with(text, budget, &allow);
        if parts.len() <= MAX_PARTS || cards == 0 {
            return parts;
        }
        budget = cards - 1;
    }
}

/// The split with at most `budget` cards, and how many it made.
fn split_with(text: &str, budget: usize, allow: &dyn Fn(&str) -> bool) -> (Vec<Part>, usize) {
    let mut parts = Vec::new();
    let mut pending: Vec<&str> = Vec::new();
    let mut cards = 0;
    let mut fenced = false;
    let flush = |pending: &mut Vec<&str>, parts: &mut Vec<Part>| {
        let start = pending.iter().position(|l| !is_blank(l));
        let end = pending.iter().rposition(|l| !is_blank(l));
        if let (Some(start), Some(end)) = (start, end) {
            parts.push(Part::Text {
                text: pending[start..=end].join("\n"),
                runs: None,
            });
        }
        pending.clear();
    };
    for line in text.split('\n') {
        if is_fence(line) {
            fenced = !fenced;
        }
        match sole_url(line) {
            Some(url) if !fenced && cards < budget && allow(url) => {
                flush(&mut pending, &mut parts);
                parts.push(Part::LinkPreview {
                    url: url.to_owned(),
                    title: None,
                    site: None,
                    image: None,
                });
                cards += 1;
            }
            _ => pending.push(line),
        }
    }
    if cards == 0 {
        return (
            vec![Part::Text {
                text: text.to_owned(),
                runs: None,
            }],
            0,
        );
    }
    flush(&mut pending, &mut parts);
    (parts, cards)
}
