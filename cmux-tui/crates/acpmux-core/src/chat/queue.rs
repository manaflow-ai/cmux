//! A waiting prompt's text, read from its raw line in bounded pieces: the head a window carries,
//! and a `blob` that goes on from a token. No path here reads a line whole.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]

use super::source::RawSource;
use acpmux_book::translate::QueueEntry;
use acpmux_client::wire::{MAX_PAGE_BYTES, QueueItem};
use std::io;

/// One read from the start of an entry's raw line: the id and the text's first KB come from it.
pub const HEAD_READ: usize = 16 * 1024;
/// A head's text, as its escaped JSON: at most this many bytes.
pub const HEAD_TEXT: usize = 1024;
/// The entries a window and a resume's state frame carry.
pub const MAX_HEADS: usize = 64;
/// A prompt's `blob` scans its line this much at a time...
pub const SCAN_CHUNK: usize = 16 * 1024;
/// ...and at most this much in one request.
pub const SCAN_LIMIT: u64 = 1024 * 1024;

const TEXT: [&[u8]; 2] = [b"msg", b"text"];
const PROMPT_ID: [&[u8]; 2] = [b"msg", b"promptId"];

/// Where a waiting prompt's scan stands: an offset in its decoded text and the byte of its line
/// that offset is at, always between two characters. On the wire: 32 hex digits.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Token {
    pub text: u64,
    pub line: u64,
}

impl Token {
    pub fn encode(self) -> String {
        format!("{:016x}{:016x}", self.text, self.line)
    }

    pub fn decode(token: &str) -> Option<Self> {
        if token.len() != 32 || !token.is_ascii() {
            return None;
        }
        let text = u64::from_str_radix(token.get(..16)?, 16).ok()?;
        let line = u64::from_str_radix(token.get(16..)?, 16).ok()?;
        Some(Self { text, line })
    }
}

/// One head: one read of at most [`HEAD_READ`] bytes from the start of the entry's line. A text
/// that does not begin in it goes empty; the length is the entry's own.
pub fn head(source: &mut dyn RawSource, entry: &QueueEntry) -> io::Result<QueueItem> {
    let piece = source.read_at(entry.place, 0, HEAD_READ)?;
    let bytes = piece.bytes.as_slice();
    let id = find_string(bytes, &PROMPT_ID)
        .and_then(|at| {
            let mut out = Vec::new();
            decode_into(bytes, at, usize::MAX, &mut out).ended.then_some(out)
        })
        .and_then(|id| String::from_utf8(id).ok())
        .unwrap_or_else(|| format!("#{:016x}", entry.id_hash));
    let text = find_string(bytes, &TEXT)
        .map(|at| {
            let mut out = Vec::new();
            decode_into(bytes, at, HEAD_TEXT, &mut out);
            String::from_utf8(out).unwrap_or_default()
        })
        .unwrap_or_default();
    Ok(QueueItem {
        id,
        text,
        len: u64::from(entry.text_len),
        held: entry.held(),
        at: entry.at_ms(),
    })
}

/// A waiting prompt's `blob`: the bytes of `[start, start + len)` of its decoded text that one
/// request reaches, and the token where its scan stopped when the text goes on.
#[derive(Debug, Default, Eq, PartialEq)]
pub struct PromptRead {
    pub start: u64,
    pub bytes: Vec<u8>,
    pub next: Option<Token>,
    pub total: u64,
    /// Line bytes this request scanned: at most [`SCAN_LIMIT`].
    pub scanned: u64,
}

#[derive(Debug, Eq, PartialEq)]
pub enum PromptError {
    /// The token is not inside the entry's line.
    TokenOutside,
    /// The range starts before the token's offset: a token only goes forward.
    BeforeToken,
    /// The text does not begin in the line's first [`HEAD_READ`] bytes.
    NoText,
    /// The line ended inside its text.
    Truncated,
}

pub fn read_prompt(
    source: &mut dyn RawSource,
    entry: &QueueEntry,
    start: Option<u64>,
    len: u64,
    from: Option<Token>,
) -> io::Result<Result<PromptRead, PromptError>> {
    let total = u64::from(entry.text_len);
    let mut at = match from {
        Some(token) if token.line >= u64::from(entry.span) || token.text > total => {
            return Ok(Err(PromptError::TokenOutside));
        }
        Some(token) => token,
        None => {
            let piece = source.read_at(entry.place, 0, HEAD_READ)?;
            let Some(text) = find_string(&piece.bytes, &TEXT) else {
                return Ok(Err(PromptError::NoText));
            };
            Token { text: 0, line: text as u64 }
        }
    };
    let start = start.unwrap_or(at.text);
    if start < at.text {
        return Ok(Err(PromptError::BeforeToken));
    }
    let want = len.min(MAX_PAGE_BYTES as u64);
    let end = start.saturating_add(want).min(total);
    let mut read = PromptRead { start: start.min(total), total, ..PromptRead::default() };
    let mut ended = false;
    while read.scanned < SCAN_LIMIT && at.text < end {
        let max = SCAN_CHUNK.min(usize::try_from(SCAN_LIMIT - read.scanned).unwrap_or(SCAN_CHUNK));
        let piece = source.read_at(entry.place, at.line, max)?;
        if piece.bytes.is_empty() {
            return Ok(Err(PromptError::Truncated));
        }
        let mut offset = 0usize;
        loop {
            if at.text >= end {
                break;
            }
            match next_char(&piece.bytes, offset) {
                Step::Char { bytes, len, next } => {
                    let first = at.text;
                    for (index, byte) in bytes.iter().take(len).enumerate() {
                        let position = first.saturating_add(index as u64);
                        // A character begun before `end` goes out whole: the token after it
                        // is past it, so a byte left out here would be lost.
                        if position >= start && first < end {
                            read.bytes.push(*byte);
                        }
                    }
                    at.text = first.saturating_add(len as u64);
                    at.line = at.line.saturating_add((next - offset) as u64);
                    offset = next;
                }
                Step::End => {
                    ended = true;
                    break;
                }
                Step::Incomplete => break,
            }
        }
        read.scanned = read.scanned.saturating_add(offset as u64);
        if ended {
            break;
        }
        if offset == 0 {
            // A piece that holds no whole character: the line ends inside an escape.
            if piece.ends || max < SCAN_CHUNK {
                return Ok(Err(PromptError::Truncated));
            }
            break;
        }
    }
    if !ended && at.text < total {
        read.next = Some(at);
    }
    Ok(Ok(read))
}

/// The byte after the opening quote of the string at `path` (object members from the line's
/// top-level object), when it lies in `bytes`. A piece cut short answers what it holds.
pub fn find_string(bytes: &[u8], path: &[&[u8]]) -> Option<usize> {
    let mut walk = Walk { bytes, at: 0 };
    walk.find(path)
}

struct Walk<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Walk<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn space(&mut self) {
        while self.peek().is_some_and(|byte| byte.is_ascii_whitespace()) {
            self.at += 1;
        }
    }

    fn eat(&mut self, byte: u8) -> Option<()> {
        self.space();
        (self.peek()? == byte).then(|| self.at += 1)
    }

    /// The index of the closing quote of the string whose content starts at `self.at`.
    fn string_end(&self) -> Option<usize> {
        let mut at = self.at;
        loop {
            match *self.bytes.get(at)? {
                b'"' => return Some(at),
                b'\\' => at += 2,
                _ => at += 1,
            }
        }
    }

    fn skip_value(&mut self) -> Option<()> {
        self.space();
        match self.peek()? {
            b'"' => {
                self.at += 1;
                self.at = self.string_end()? + 1;
            }
            b'{' | b'[' => {
                let mut depth = 0usize;
                loop {
                    match self.peek()? {
                        b'"' => {
                            self.at += 1;
                            self.at = self.string_end()?;
                        }
                        b'{' | b'[' => depth += 1,
                        b'}' | b']' => {
                            depth -= 1;
                            if depth == 0 {
                                self.at += 1;
                                return Some(());
                            }
                        }
                        _ => {}
                    }
                    self.at += 1;
                }
            }
            _ => {
                while self.peek().is_some_and(|byte| !matches!(byte, b',' | b'}' | b']')) {
                    self.at += 1;
                }
                self.peek()?;
            }
        }
        Some(())
    }

    fn find(&mut self, path: &[&[u8]]) -> Option<usize> {
        let (want, rest) = path.split_first()?;
        self.eat(b'{')?;
        loop {
            self.space();
            if self.peek()? == b'}' {
                return None;
            }
            self.eat(b'"')?;
            let key_end = self.string_end()?;
            let key = self.bytes.get(self.at..key_end)?;
            self.at = key_end + 1;
            self.eat(b':')?;
            if key == *want {
                if rest.is_empty() {
                    self.eat(b'"')?;
                    return Some(self.at);
                }
                return self.find(rest);
            }
            self.skip_value()?;
            self.space();
            match self.peek()? {
                b',' => self.at += 1,
                _ => return None,
            }
        }
    }
}

enum Step {
    /// One decoded character: its UTF-8 bytes (the first `len`), and where the next starts.
    Char { bytes: [u8; 4], len: usize, next: usize },
    /// The closing quote.
    End,
    /// The piece ends inside this character.
    Incomplete,
}

/// The character of a JSON string's content at `at`. Raw UTF-8 passes through whole, so a
/// step always ends between two characters.
fn next_char(bytes: &[u8], at: usize) -> Step {
    let Some(&first) = bytes.get(at) else { return Step::Incomplete };
    match first {
        b'"' => Step::End,
        b'\\' => {
            let Some(&kind) = bytes.get(at + 1) else { return Step::Incomplete };
            let simple = match kind {
                b'"' => Some(b'"'),
                b'\\' => Some(b'\\'),
                b'/' => Some(b'/'),
                b'b' => Some(0x08),
                b'f' => Some(0x0c),
                b'n' => Some(b'\n'),
                b'r' => Some(b'\r'),
                b't' => Some(b'\t'),
                _ => None,
            };
            if let Some(byte) = simple {
                return Step::Char { bytes: [byte, 0, 0, 0], len: 1, next: at + 2 };
            }
            let Some(high) = hex4(bytes, at + 2) else { return Step::Incomplete };
            let (code, next) = if (0xd800..0xdc00).contains(&high) {
                // A high surrogate pairs with a `\u` escape of a low one right after it; else
                // it is U+FFFD. The piece may end before the pair does.
                match (bytes.get(at + 6), bytes.get(at + 7)) {
                    (None, _) | (Some(b'\\'), None) => return Step::Incomplete,
                    (Some(b'\\'), Some(b'u')) => match hex4(bytes, at + 8) {
                        Some(low) if (0xdc00..0xe000).contains(&low) => {
                            (0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00), at + 12)
                        }
                        None if bytes.len() < at + 12 => return Step::Incomplete,
                        _ => (0xfffd, at + 6),
                    },
                    _ => (0xfffd, at + 6),
                }
            } else {
                (high, at + 6)
            };
            let character = char::from_u32(code).unwrap_or('\u{fffd}');
            let mut out = [0u8; 4];
            let len = character.encode_utf8(&mut out).len();
            Step::Char { bytes: out, len, next }
        }
        _ => {
            let len = match first {
                0x00..=0x7f => 1,
                0xc0..=0xdf => 2,
                0xe0..=0xef => 3,
                _ => 4,
            };
            let Some(piece) = bytes.get(at..at + len) else { return Step::Incomplete };
            let mut out = [0u8; 4];
            for (slot, byte) in out.iter_mut().zip(piece) {
                *slot = *byte;
            }
            Step::Char { bytes: out, len, next: at + len }
        }
    }
}

fn hex4(bytes: &[u8], at: usize) -> Option<u32> {
    let digits = std::str::from_utf8(bytes.get(at..at + 4)?).ok()?;
    u32::from_str_radix(digits, 16).ok()
}

struct Decoded {
    ended: bool,
}

/// Decodes the string content at `at` into `out`, stopping before a character whose escaped
/// JSON form would take what was taken past `max_escaped` bytes.
fn decode_into(bytes: &[u8], mut at: usize, max_escaped: usize, out: &mut Vec<u8>) -> Decoded {
    let mut escaped = 0usize;
    loop {
        match next_char(bytes, at) {
            Step::Char { bytes: character, len, next } => {
                let cost = escaped_len(character.first().copied().unwrap_or_default(), len);
                if escaped.saturating_add(cost) > max_escaped {
                    return Decoded { ended: false };
                }
                escaped += cost;
                out.extend(character.iter().take(len));
                at = next;
            }
            Step::End => return Decoded { ended: true },
            Step::Incomplete => return Decoded { ended: false },
        }
    }
}

/// The length of one character as JSON escapes it.
fn escaped_len(first: u8, len: usize) -> usize {
    match first {
        b'"' | b'\\' | b'\n' | b'\r' | b'\t' | 0x08 | 0x0c => 2,
        0x00..=0x1f => 6,
        _ => len,
    }
}

#[cfg(test)]
mod tests;
