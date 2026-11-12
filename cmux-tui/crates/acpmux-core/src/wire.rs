//! Framing and the shared stream request shapes.
//!
//! A frame is a bounded unit on the wire. The decoder never allocates for a
//! frame larger than [`MAX_FRAME_BYTES`], and the request types do not carry a
//! list or chat payload: later stream implementations fill one frame at a
//! time.

use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error as _};
use std::fmt;

/// The inclusive encoded-frame limit from the v2 protocol.
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;
pub const MAX_PAGE_BYTES: usize = 256 * 1024;
const HEADER_BYTES: usize = std::mem::size_of::<u32>();
const KIND_BYTES: usize = 1;
const MAX_PAYLOAD_BYTES: usize = MAX_FRAME_BYTES - HEADER_BYTES - KIND_BYTES;

/// A generic stream name. The wire layer does not know which stream is being
/// served; `list`, `chat:<id>` and `status` are interpreted by the caller.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Stream(pub String);

impl Stream {
    pub fn new(name: impl Into<String>) -> Self {
        Self(name.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for Stream {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}

impl From<String> for Stream {
    fn from(value: String) -> Self {
        Self(value)
    }
}

/// A durable stream sequence. Cursors are opaque to the wire layer but are
/// represented as integers so clients can persist them without loss.
#[derive(Clone, Copy, Debug, Default, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Cursor(pub u64);

impl From<u64> for Cursor {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

/// The side of an anchor on which a window begins or ends.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnchorSide {
    Before,
    After,
    Around,
}

/// A row anchor. `End` opens at the newest rows; an id anchor restores a
/// person's previous viewport.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Anchor {
    End,
    Row { row_id: u64, side: AnchorSide },
    List { key: ListKey, side: AnchorSide },
}

/// Stable key for the list's recent-activity ordering. Offset paging is not
/// stable while summaries are being updated; this keyset is.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListKey {
    pub last_activity: u64,
    pub chat_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Position {
    Row(u64),
    List(ListKey),
}

impl Serialize for Anchor {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::End => serializer.serialize_str("end"),
            Self::Row { row_id, side } => {
                #[derive(Serialize)]
                #[serde(rename_all = "camelCase")]
                struct RowAnchor {
                    row_id: u64,
                    side: AnchorSide,
                }
                RowAnchor { row_id: *row_id, side: *side }.serialize(serializer)
            }
            Self::List { key, side } => {
                #[derive(Serialize)]
                #[serde(rename_all = "camelCase")]
                struct ListAnchor<'a> {
                    key: &'a ListKey,
                    side: AnchorSide,
                }
                ListAnchor { key, side: *side }.serialize(serializer)
            }
        }
    }
}

impl<'de> Deserialize<'de> for Anchor {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct RowAnchor {
            row_id: u64,
            side: AnchorSide,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ListAnchor {
            key: ListKey,
            side: AnchorSide,
        }
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum AnchorWire {
            End(String),
            Row(RowAnchor),
            List(ListAnchor),
        }
        match AnchorWire::deserialize(deserializer)? {
            AnchorWire::End(value) if value == "end" => Ok(Self::End),
            AnchorWire::End(value) => Err(D::Error::custom(format!("invalid anchor {value:?}"))),
            AnchorWire::Row(row) => Ok(Self::Row { row_id: row.row_id, side: row.side }),
            AnchorWire::List(anchor) => Ok(Self::List { key: anchor.key, side: anchor.side }),
        }
    }
}

/// The shared subscription request. A subscription may resume from a cursor or
/// open around an anchor, but it never asks for an unbounded reply.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sub {
    pub sid: String,
    pub stream: Stream,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<Cursor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor: Option<Anchor>,
    #[serde(default = "default_window", skip_serializing_if = "Option::is_none")]
    pub window: Option<u16>,
}

/// Descriptive aliases used by clients that model requests explicitly.
pub type SubRequest = Sub;

fn default_window() -> Option<u16> {
    Some(100)
}

impl Sub {
    pub fn new(sid: impl Into<String>, stream: impl Into<Stream>) -> Self {
        Self {
            sid: sid.into(),
            stream: stream.into(),
            cursor: None,
            anchor: None,
            window: default_window(),
        }
    }

    pub fn from_cursor(mut self, cursor: impl Into<Cursor>) -> Self {
        self.cursor = Some(cursor.into());
        self.anchor = None;
        self
    }

    pub fn around(mut self, anchor: Anchor, window: u16) -> Self {
        self.anchor = Some(anchor);
        self.cursor = None;
        self.window = Some(window);
        self
    }
}

/// Which side of a row a page reads.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PageSide {
    Before,
    After,
}

/// A bounded page request. `maxBytes` is a budget for the one frame returned;
/// it is not a request to loop until a whole list has been assembled.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    pub sid: String,
    pub stream: Stream,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<Position>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<Position>,
    #[serde(default = "default_page_bytes")]
    pub max_bytes: u32,
}

/// Descriptive alias used by request routers.
pub type PageRequest = Page;

fn default_page_bytes() -> u32 {
    256 * 1024
}

impl Page {
    pub fn new(
        sid: impl Into<String>,
        stream: impl Into<Stream>,
        side: PageSide,
        row_id: u64,
    ) -> Self {
        Self {
            sid: sid.into(),
            stream: stream.into(),
            before: (side == PageSide::Before).then_some(Position::Row(row_id)),
            after: (side == PageSide::After).then_some(Position::Row(row_id)),
            max_bytes: default_page_bytes(),
        }
    }

    pub fn with_max_bytes(mut self, max_bytes: u32) -> Self {
        self.max_bytes = max_bytes;
        self
    }

    pub fn side(&self) -> Option<(PageSide, &Position)> {
        match (&self.before, &self.after) {
            (Some(row_id), None) => Some((PageSide::Before, row_id)),
            (None, Some(row_id)) => Some((PageSide::After, row_id)),
            _ => None,
        }
    }
}

/// A generic bounded window shared by list and chat streams.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Window<T> {
    pub sid: String,
    pub cursor: u64,
    pub rows: Vec<T>,
    pub has_before: bool,
    pub has_after: bool,
}

/// A generic delta shared by list and chat streams.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", tag = "op")]
pub enum Delta<T> {
    Summary { sid: String, seq: u64, summary: T },
    Gone { sid: String, seq: u64, chat_id: String },
    Queue { sid: String, seq: u64, bytes: u64 },
}

pub fn delta_frame<T: Serialize>(delta: &Delta<T>) -> Result<Frame, FrameError> {
    Frame::json(FrameKind::Delta, delta)
}

/// A frame kind. The payload is encoded separately so the framing layer can be
/// reused by chat, list and status streams without knowing their row types.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum FrameKind {
    Hello = 1,
    Window = 2,
    Delta = 3,
    Page = 4,
    Blob = 5,
    Ack = 6,
    Dropped = 7,
    Error = 8,
}

impl TryFrom<u8> for FrameKind {
    type Error = FrameError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Hello),
            2 => Ok(Self::Window),
            3 => Ok(Self::Delta),
            4 => Ok(Self::Page),
            5 => Ok(Self::Blob),
            6 => Ok(Self::Ack),
            7 => Ok(Self::Dropped),
            8 => Ok(Self::Error),
            _ => Err(FrameError::UnknownKind(value)),
        }
    }
}

/// One bounded frame, including its kind and opaque payload.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Frame {
    pub kind: FrameKind,
    payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: FrameKind, payload: impl Into<Vec<u8>>) -> Result<Self, FrameError> {
        let payload = payload.into();
        if payload.len() > MAX_PAYLOAD_BYTES {
            return Err(FrameError::TooLarge { bytes: payload.len() + HEADER_BYTES + KIND_BYTES });
        }
        Ok(Self { kind, payload })
    }

    pub fn json<T: Serialize>(kind: FrameKind, value: &T) -> Result<Self, FrameError> {
        let payload = serde_json::to_vec(value).map_err(FrameError::Encode)?;
        Self::new(kind, payload)
    }

    pub fn payload(&self) -> &[u8] {
        &self.payload
    }

    pub fn decode_json<T: for<'de> Deserialize<'de>>(&self) -> Result<T, FrameError> {
        serde_json::from_slice(&self.payload).map_err(FrameError::Decode)
    }

    pub fn encoded_len(&self) -> usize {
        HEADER_BYTES + KIND_BYTES + self.payload.len()
    }

    /// Encodes `len u32 | kind u8 | payload`. The length includes the kind and
    /// payload, which lets a decoder reject an oversized frame before allocating.
    pub fn encode(&self) -> Vec<u8> {
        let body_len = KIND_BYTES + self.payload.len();
        let mut out = Vec::with_capacity(HEADER_BYTES + body_len);
        out.extend_from_slice(&(body_len as u32).to_be_bytes());
        out.push(self.kind as u8);
        out.extend_from_slice(&self.payload);
        out
    }

    pub fn from_encoded(encoded: &[u8]) -> Result<Self, FrameError> {
        let mut decoder = FrameDecoder::default();
        let frames = decoder.push(encoded)?;
        if !decoder.is_empty() {
            return Err(FrameError::Truncated);
        }
        match frames.as_slice() {
            [frame] => Ok(frame.clone()),
            [] => Err(FrameError::Truncated),
            _ => Err(FrameError::TrailingBytes),
        }
    }
}

/// Incremental decoder for a byte stream. It retains at most one bounded frame
/// plus its four byte header.
#[derive(Default)]
pub struct FrameDecoder {
    bytes: Vec<u8>,
    head: usize,
    expected: Option<usize>,
}

impl FrameDecoder {
    pub fn is_empty(&self) -> bool {
        self.head == self.bytes.len() && self.expected.is_none()
    }

    pub fn push(&mut self, input: &[u8]) -> Result<Vec<Frame>, FrameError> {
        self.bytes.extend_from_slice(input);
        let mut frames = Vec::new();
        loop {
            if self.expected.is_none() {
                if self.bytes.len().saturating_sub(self.head) < HEADER_BYTES {
                    break;
                }
                let header = self
                    .bytes
                    .get(self.head..self.head + HEADER_BYTES)
                    .ok_or(FrameError::Truncated)?;
                let mut length = [0_u8; HEADER_BYTES];
                length.copy_from_slice(header);
                let len = u32::from_be_bytes(length) as usize;
                if !(KIND_BYTES..=MAX_FRAME_BYTES - HEADER_BYTES).contains(&len) {
                    return Err(FrameError::InvalidLength(len));
                }
                self.head += HEADER_BYTES;
                self.expected = Some(len);
            }
            let Some(expected) = self.expected else {
                return Err(FrameError::Truncated);
            };
            if self.bytes.len().saturating_sub(self.head) < expected {
                break;
            }
            let body = self.bytes[self.head..self.head + expected].to_vec();
            self.head += expected;
            self.expected = None;
            let (kind, payload) = body.split_first().ok_or(FrameError::Truncated)?;
            frames.push(Frame::new(FrameKind::try_from(*kind)?, payload.to_vec())?);
        }
        if self.head == self.bytes.len() {
            self.bytes.clear();
            self.head = 0;
        } else if self.head >= 4096 && self.head > self.bytes.len() / 2 {
            self.bytes.drain(..self.head);
            self.head = 0;
        }
        Ok(frames)
    }
}

/// Errors raised by bounded frame encoding and decoding.
#[derive(Debug)]
pub enum FrameError {
    TooLarge { bytes: usize },
    InvalidLength(usize),
    UnknownKind(u8),
    Truncated,
    TrailingBytes,
    Encode(serde_json::Error),
    Decode(serde_json::Error),
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLarge { bytes } => {
                write!(f, "frame is {bytes} bytes; maximum is {MAX_FRAME_BYTES}")
            }
            Self::InvalidLength(bytes) => write!(f, "invalid frame body length {bytes}"),
            Self::UnknownKind(kind) => write!(f, "unknown frame kind {kind}"),
            Self::Truncated => f.write_str("truncated frame"),
            Self::TrailingBytes => f.write_str("more than one frame in input"),
            Self::Encode(error) => write!(f, "frame payload encode failed: {error}"),
            Self::Decode(error) => write!(f, "frame payload decode failed: {error}"),
        }
    }
}

impl std::error::Error for FrameError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sub_and_page_are_shared_shapes() {
        let sub = Sub::new("s1", "list").from_cursor(42);
        let text = serde_json::to_string(&sub).unwrap();
        assert_eq!(text, r#"{"sid":"s1","stream":"list","cursor":42,"window":100}"#);
        let anchored = Sub::new("s1", "list").around(Anchor::End, 100);
        assert_eq!(
            serde_json::to_value(anchored).unwrap().get("anchor"),
            Some(&serde_json::json!("end"))
        );
        let anchored = Sub::new("s1", "list")
            .around(Anchor::Row { row_id: 11, side: AnchorSide::Around }, 100);
        assert_eq!(
            serde_json::to_value(anchored).unwrap().get("anchor"),
            Some(&serde_json::json!({"rowId": 11, "side": "around"}))
        );
        let page = Page::new("s1", "list", PageSide::After, 11);
        assert_eq!(serde_json::to_value(&page).unwrap().get("after"), Some(&serde_json::json!(11)));
        assert_eq!(
            serde_json::to_value(page).unwrap().get("maxBytes"),
            Some(&serde_json::json!(262_144))
        );
    }

    #[test]
    fn decoder_handles_chunks_and_rejects_oversized_frames() {
        let frame = Frame::json(FrameKind::Window, &serde_json::json!({"seq": 7})).unwrap();
        let encoded = frame.encode();
        let mut decoder = FrameDecoder::default();
        assert!(decoder.push(encoded.get(..2).unwrap()).unwrap().is_empty());
        assert_eq!(decoder.push(encoded.get(2..).unwrap()).unwrap(), vec![frame]);
        assert!(matches!(
            Frame::new(FrameKind::Delta, vec![0; MAX_FRAME_BYTES]),
            Err(FrameError::TooLarge { .. })
        ));
    }
}
