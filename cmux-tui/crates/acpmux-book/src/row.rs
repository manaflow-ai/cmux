//! The row: what the page draws as one item, and its wire text.
//!
//! The daemon decides a row's kind, text, group and place; the page draws what it is given. A
//! row's wire text is compact JSON with a fixed key order,
//!
//! ```text
//! {"id":48211,"rev":1,"kind":"tool","turn":9120,"group":48190,"at":1794480726,"open":false,
//!  "body":{...},"est":3,"blob":{"bytes":5242880,"preview":"..."}}
//! ```
//!
//! (one line; `turn`, `group` and `blob` only when present). It is encoded once, by
//! [`Row::encode`], when the row settles; the log stores those bytes and every reader is handed
//! them as they are. Nothing in the daemon parses a row text again.
//!
//! **Size.** A row text is at most [`MAX_ROW_TEXT`] (16 KB). A row whose body would pass that (a
//! 5 MB tool output, an image, a diff) is stored out of line: the whole body is the blob
//! `blobs/<rowId>`, and the row keeps a small body (the [`Outline::head`]) and a preview of at
//! most [`MAX_PREVIEW`] (4 KB). So a window of 400 rows has a hard ceiling, whatever the chat
//! holds.

use crate::json;
use std::io::Write;

/// The most bytes a row's wire text may have.
pub const MAX_ROW_TEXT: usize = 16 * 1024;
/// The most bytes of a blob's preview inside its row, counted as written (escapes included).
pub const MAX_PREVIEW: usize = 4 * 1024;

/// What a row is. The page picks its renderer by this.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RowKind {
    /// A prompt from a person (queued, sent or steered).
    User,
    /// Assistant text.
    Text,
    /// Assistant thinking.
    Thinking,
    /// A tool call and its result.
    Tool,
    /// A fold ("Worked for 1m 9s"); its children name it in `group`.
    Group,
    /// A line from the service (a turn ended, a model changed).
    Notice,
    /// A question to the person (a permission, a choice).
    Ask,
    /// A plan.
    Plan,
    /// An image.
    Image,
    /// A subagent; it names a child book.
    Sub,
}

impl RowKind {
    /// Every kind, in the order of the design's list.
    pub const ALL: [RowKind; 10] = [
        RowKind::User,
        RowKind::Text,
        RowKind::Thinking,
        RowKind::Tool,
        RowKind::Group,
        RowKind::Notice,
        RowKind::Ask,
        RowKind::Plan,
        RowKind::Image,
        RowKind::Sub,
    ];

    /// The kind's name on the wire.
    pub fn as_str(self) -> &'static str {
        match self {
            RowKind::User => "user",
            RowKind::Text => "text",
            RowKind::Thinking => "thinking",
            RowKind::Tool => "tool",
            RowKind::Group => "group",
            RowKind::Notice => "notice",
            RowKind::Ask => "ask",
            RowKind::Plan => "plan",
            RowKind::Image => "image",
            RowKind::Sub => "sub",
        }
    }

    /// The kind with this wire name.
    pub fn parse(name: &str) -> Option<RowKind> {
        RowKind::ALL.into_iter().find(|kind| kind.as_str() == name)
    }
}

/// One row, ready to encode. `body` is the row's per-kind JSON, already compact, built by the
/// translator; this crate copies it and never looks inside.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Row<'a> {
    /// The rowId: per chat, rising, given when the row begins; its place in the book for good.
    /// Never 0.
    pub id: u64,
    /// 1 when the row settles; rises on the rare change after that (a permission answered).
    pub rev: u32,
    pub kind: RowKind,
    /// The rowId of the prompt that began the row's turn.
    pub turn: Option<u64>,
    /// The rowId of the group row this row folds under.
    pub group: Option<u64>,
    /// Seconds since the epoch.
    pub at: u64,
    /// True only for a live row (one that can still grow). A row in a segment is never open.
    pub open: bool,
    /// The per-kind body: one compact JSON value.
    pub body: &'a str,
    /// Lines, for the page's height estimate.
    pub est: u32,
}

/// What a row keeps inline when its body must go out of line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Outline<'a> {
    /// The small body kept in the row (a tool's name and title without its output): one compact
    /// JSON value.
    pub head: &'a str,
    /// The start of what the blob shows, as plain text. Cut to [`MAX_PREVIEW`] on a character
    /// boundary.
    pub preview: &'a str,
}

/// Where a row's body went.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placement {
    /// The whole body is in the row text.
    Inline,
    /// The row text holds the head and a preview; the caller writes the row's `body`, `bytes`
    /// long, as the blob `blobs/<rowId>` ([`crate::log::Log::write_blob`]) before it appends
    /// the row.
    Blob { bytes: u64 },
}

/// Why a row could not be encoded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowError {
    /// The rowId is 0.
    ZeroId,
    /// The body is not one compact JSON value.
    Body,
    /// The outline's head is not one compact JSON value.
    Head,
    /// The row is over [`MAX_ROW_TEXT`] even with its body out of line: the head is too large.
    TooLarge { bytes: usize },
}

impl std::fmt::Display for RowError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RowError::ZeroId => write!(f, "a row's id is never 0"),
            RowError::Body => write!(f, "the row's body is not one compact JSON value"),
            RowError::Head => write!(f, "the outline's head is not one compact JSON value"),
            RowError::TooLarge { bytes } => {
                write!(f, "the row is {bytes} bytes with its body out of line; the most is 16384")
            }
        }
    }
}

impl std::error::Error for RowError {}

impl Row<'_> {
    /// Writes the row's wire text into `out` (cleared first). Costs the row's own length.
    ///
    /// When the text with the whole body fits [`MAX_ROW_TEXT`], that is the text. Otherwise the
    /// body goes out of line: the text carries `outline`'s head as its body and a `blob` member
    /// with the body's length and a preview. With no `outline`, the head is `{}` and the preview
    /// is the start of the body's own text.
    pub fn encode(
        &self,
        outline: Option<Outline<'_>>,
        out: &mut Vec<u8>,
    ) -> Result<Placement, RowError> {
        if self.id == 0 {
            return Err(RowError::ZeroId);
        }
        if !json::is_compact_value(self.body) {
            return Err(RowError::Body);
        }
        out.clear();
        self.write(out, self.body, None);
        if out.len() <= MAX_ROW_TEXT {
            return Ok(Placement::Inline);
        }
        let outline = outline.unwrap_or(Outline { head: "{}", preview: self.body });
        if !json::is_compact_value(outline.head) {
            return Err(RowError::Head);
        }
        let bytes = self.body.len() as u64;
        out.clear();
        self.write(out, outline.head, Some((bytes, outline.preview)));
        if out.len() > MAX_ROW_TEXT {
            return Err(RowError::TooLarge { bytes: out.len() });
        }
        Ok(Placement::Blob { bytes })
    }

    /// Encodes a body already stored in `blobs/<rowId>` using only its byte length and
    /// outline. The actor validates the body while writing it; this method never reads
    /// `self.body`, loads the blob, or constructs the full-body row as an intermediate.
    /// The caller chooses inline or blob from the final size, regardless of earlier spills.
    pub fn encode_blob(
        &self,
        bytes: u64,
        outline: Outline<'_>,
        out: &mut Vec<u8>,
    ) -> Result<Placement, RowError> {
        if self.id == 0 {
            return Err(RowError::ZeroId);
        }
        if !json::is_compact_value(outline.head) {
            return Err(RowError::Head);
        }
        if outline.head.len() > MAX_ROW_TEXT {
            return Err(RowError::TooLarge { bytes: outline.head.len() });
        }
        out.clear();
        self.write(out, outline.head, Some((bytes, outline.preview)));
        if out.len() > MAX_ROW_TEXT {
            return Err(RowError::TooLarge { bytes: out.len() });
        }
        Ok(Placement::Blob { bytes })
    }

    fn write(&self, out: &mut Vec<u8>, body: &str, blob: Option<(u64, &str)>) {
        out.extend_from_slice(b"{\"id\":");
        number(out, self.id);
        out.extend_from_slice(b",\"rev\":");
        number(out, u64::from(self.rev));
        out.extend_from_slice(b",\"kind\":\"");
        out.extend_from_slice(self.kind.as_str().as_bytes());
        out.push(b'"');
        if let Some(turn) = self.turn {
            out.extend_from_slice(b",\"turn\":");
            number(out, turn);
        }
        if let Some(group) = self.group {
            out.extend_from_slice(b",\"group\":");
            number(out, group);
        }
        out.extend_from_slice(b",\"at\":");
        number(out, self.at);
        out.extend_from_slice(if self.open { b",\"open\":true" } else { b",\"open\":false" });
        out.extend_from_slice(b",\"body\":");
        out.extend_from_slice(body.as_bytes());
        out.extend_from_slice(b",\"est\":");
        number(out, u64::from(self.est));
        if let Some((bytes, preview)) = blob {
            out.extend_from_slice(b",\"blob\":{\"bytes\":");
            number(out, bytes);
            out.extend_from_slice(b",\"preview\":\"");
            escape_into(out, preview, MAX_PREVIEW);
            out.extend_from_slice(b"\"}");
        }
        out.push(b'}');
    }
}

fn number(out: &mut Vec<u8>, value: u64) {
    // A write to a Vec cannot fail.
    let _ = write!(out, "{value}");
}

/// Appends `text` as the inside of a JSON string, stopping before a character whose escaped
/// form would take the written length past `max`.
fn escape_into(out: &mut Vec<u8>, text: &str, max: usize) {
    let mut left = max;
    let mut utf8 = [0u8; 4];
    let mut unicode: [u8; 6];
    for character in text.chars() {
        let piece: &[u8] = match character {
            '"' => b"\\\"",
            '\\' => b"\\\\",
            '\n' => b"\\n",
            '\r' => b"\\r",
            '\t' => b"\\t",
            control if (control as u32) < 0x20 => {
                let code = control as u32;
                unicode = [b'\\', b'u', b'0', b'0', hex(code / 16), hex(code % 16)];
                &unicode
            }
            other => other.encode_utf8(&mut utf8).as_bytes(),
        };
        if piece.len() > left {
            break;
        }
        left = left.saturating_sub(piece.len());
        out.extend_from_slice(piece);
    }
}

fn hex(nibble: u32) -> u8 {
    char::from_digit(nibble, 16).and_then(|digit| u8::try_from(digit).ok()).unwrap_or(b'0')
}

/// The fixed members at the front of a row text, read back without touching the body. For
/// clients and tests: the log itself never reads a row text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RowHead {
    pub id: u64,
    pub rev: u32,
    pub kind: RowKind,
    pub turn: Option<u64>,
    pub group: Option<u64>,
    pub at: u64,
    pub open: bool,
    /// Where the body's JSON starts in the text.
    pub body_at: usize,
}

impl RowHead {
    /// Reads the front of a row text written by [`Row::encode`]; `None` for any other text.
    pub fn parse(text: &[u8]) -> Option<RowHead> {
        let mut front = Front { text, at: 0 };
        front.step(b"{\"id\":")?;
        let id = front.number()?;
        front.step(b",\"rev\":")?;
        let rev = u32::try_from(front.number()?).ok()?;
        front.step(b",\"kind\":\"")?;
        let kind = RowKind::parse(front.word()?)?;
        front.step(b"\"")?;
        let turn = match front.step(b",\"turn\":") {
            Some(()) => Some(front.number()?),
            None => None,
        };
        let group = match front.step(b",\"group\":") {
            Some(()) => Some(front.number()?),
            None => None,
        };
        front.step(b",\"at\":")?;
        let at = front.number()?;
        let open = if front.step(b",\"open\":true").is_some() {
            true
        } else {
            front.step(b",\"open\":false")?;
            false
        };
        front.step(b",\"body\":")?;
        Some(RowHead { id, rev, kind, turn, group, at, open, body_at: front.at })
    }
}

struct Front<'a> {
    text: &'a [u8],
    at: usize,
}

impl<'a> Front<'a> {
    fn rest(&self) -> &'a [u8] {
        self.text.get(self.at..).unwrap_or_default()
    }

    /// Steps over `literal` when the text continues with it.
    fn step(&mut self, literal: &[u8]) -> Option<()> {
        if !self.rest().starts_with(literal) {
            return None;
        }
        self.at = self.at.saturating_add(literal.len());
        Some(())
    }

    fn number(&mut self) -> Option<u64> {
        let rest = self.rest();
        let digits = rest.iter().take_while(|byte| byte.is_ascii_digit()).count();
        let value = std::str::from_utf8(rest.get(..digits)?).ok()?.parse().ok()?;
        self.at = self.at.saturating_add(digits);
        Some(value)
    }

    fn word(&mut self) -> Option<&'a str> {
        let rest = self.rest();
        let letters = rest.iter().take_while(|byte| byte.is_ascii_lowercase()).count();
        let word = std::str::from_utf8(rest.get(..letters)?).ok()?;
        self.at = self.at.saturating_add(letters);
        Some(word)
    }
}
