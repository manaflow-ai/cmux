//! Framing and the shared stream request shapes.
//!
//! A frame is a bounded unit on the wire. The decoder never allocates for a
//! frame larger than [`MAX_FRAME_BYTES`], and the request types do not carry a
//! list or chat payload: later stream implementations fill one frame at a
//! time.

use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error as _};
use std::fmt;
use std::mem::size_of;

pub use acpmux_list_types::folders::FolderRow;
pub use acpmux_list_types::{ListFilter, OriginState};

/// The inclusive encoded-frame limit from the v2 protocol.
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;
pub const MAX_PAGE_BYTES: usize = 256 * 1024;
pub const MAX_REPLAY_FRAME_BYTES: usize = 256 * 1024;
pub const CREDIT_WINDOW_BYTES: u64 = 1024 * 1024;
pub const CONNECTION_BUDGET_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_SUBSCRIPTIONS: usize = 256;
pub const MAX_IDENTIFIER_BYTES: usize = 256;

/// Subscription and request identifiers have one UTF-8 byte bound.
pub fn identifier_fits(value: &str) -> bool {
    value.len() <= MAX_IDENTIFIER_BYTES
}

const HEADER_BYTES: usize = size_of::<u32>();
const KIND_BYTES: usize = 1;
const MAX_PAYLOAD_BYTES: usize = MAX_FRAME_BYTES - HEADER_BYTES - KIND_BYTES;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "method", content = "params", rename_all = "lowercase")]
pub enum Request {
    Hello(Hello),
    Sub(Sub),
    Page(Page),
    Credit(Credit),
    Unsub(Unsub),
    Blob(Blob),
}

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
    pub origin: String,
}

/// Stable position key for the folders view.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderPosition {
    pub at: u64,
    pub origin: String,
    pub folder: String,
}

/// Identity used by keyed folder pages. Activity time is intentionally absent:
/// a lookup is by `(origin, folder)` and the supplied cursor time must never
/// become part of identity.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderIdentity {
    pub origin: String,
    pub folder: String,
}

pub type FolderKey = FolderIdentity;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Position {
    Row(u64),
    List(ListKey),
    Folder(FolderPosition),
}

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum PageKey {
    Summary(ListKey),
    Folder(FolderIdentity),
}

impl From<ListKey> for PageKey {
    fn from(value: ListKey) -> Self {
        Self::Summary(value)
    }
}

impl From<FolderIdentity> for PageKey {
    fn from(value: FolderIdentity) -> Self {
        Self::Folder(value)
    }
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
    pub edition: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor: Option<Anchor>,
    #[serde(default = "default_window", skip_serializing_if = "Option::is_none")]
    pub window: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view: Option<ListView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<ListFilter>,
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
            edition: None,
            anchor: None,
            window: default_window(),
            view: None,
            rows: None,
            filter: None,
        }
    }

    pub fn from_cursor(mut self, cursor: impl Into<Cursor>) -> Self {
        self.cursor = Some(cursor.into());
        self.anchor = None;
        self
    }

    pub fn from_cursor_in_edition(mut self, cursor: impl Into<Cursor>, edition: u32) -> Self {
        self.cursor = Some(cursor.into());
        self.edition = Some(edition);
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

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ListView {
    All,
    Live,
    Folders,
}

/// Folders are bounded windows, never whole-view mirrors.
pub fn validate_mirror_view(view: Option<ListView>) -> Result<(), FrameError> {
    if matches!(view, Some(ListView::Folders)) {
        return Err(FrameError::MirrorUnsupported);
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hello {
    pub client_kind: String,
    pub protocol: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    pub credit_window: u64,
    pub connection_budget: u64,
    pub max_subscriptions: u16,
    pub max_frame: u32,
    pub max_replay_frame: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            credit_window: CREDIT_WINDOW_BYTES,
            connection_budget: CONNECTION_BUDGET_BYTES as u64,
            max_subscriptions: MAX_SUBSCRIPTIONS as u16,
            max_frame: MAX_FRAME_BYTES as u32,
            max_replay_frame: MAX_REPLAY_FRAME_BYTES as u32,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloReply {
    pub daemon_id: String,
    pub limits: Limits,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credit {
    pub sid: String,
    pub consumed: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Unsub {
    pub sid: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReplayMark {
    Replay,
    End,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Dropped {
    pub sid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<Cursor>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Origin {
    pub id: String,
    pub state: OriginState,
    pub since: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra: Option<serde_json::Value>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keys: Option<Vec<PageKey>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view: Option<ListView>,
    #[serde(default = "default_page_bytes")]
    pub max_bytes: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<ListFilter>,
    /// On a chat: the edition the anchor's rowId is from. A page of another edition is
    /// answered `stale_edition`, never rows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edition: Option<u32>,
    /// On a chat: a group's rowId. The page holds that fold's rows, taken as open.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fold: Option<u64>,
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
            keys: None,
            view: None,
            max_bytes: default_page_bytes(),
            filter: None,
            edition: None,
            fold: None,
        }
    }

    pub fn with_max_bytes(mut self, max_bytes: u32) -> Self {
        self.max_bytes = max_bytes;
        self
    }

    /// Constructs a list page from its stable keyset anchor. Chat pages use
    /// [`Page::new`] with a row id; list pages must never use an offset.
    pub fn new_list(
        sid: impl Into<String>,
        stream: impl Into<Stream>,
        side: PageSide,
        key: ListKey,
    ) -> Self {
        Self {
            sid: sid.into(),
            stream: stream.into(),
            before: (side == PageSide::Before).then_some(Position::List(key.clone())),
            after: (side == PageSide::After).then_some(Position::List(key)),
            keys: None,
            view: None,
            max_bytes: default_page_bytes(),
            filter: None,
            edition: None,
            fold: None,
        }
    }

    pub fn new_folder(
        sid: impl Into<String>,
        stream: impl Into<Stream>,
        side: PageSide,
        key: FolderPosition,
    ) -> Self {
        Self {
            sid: sid.into(),
            stream: stream.into(),
            before: (side == PageSide::Before).then_some(Position::Folder(key.clone())),
            after: (side == PageSide::After).then_some(Position::Folder(key)),
            keys: None,
            view: Some(ListView::Folders),
            max_bytes: default_page_bytes(),
            filter: None,
            edition: None,
            fold: None,
        }
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
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Window<T> {
    pub sid: String,
    pub cursor: u64,
    pub rows: Vec<T>,
    pub has_before: bool,
    pub has_after: bool,
    #[serde(default)]
    pub edition: u32,
    #[serde(default)]
    pub origins: Vec<Origin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before_key: Option<ListKey>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after_key: Option<ListKey>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PageResult<T> {
    pub sid: String,
    pub rows: Vec<T>,
    pub has_before: bool,
    pub has_after: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cold_unread: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub deeper: Vec<ListKey>,
    #[serde(default)]
    pub before_key: Option<ListKey>,
    #[serde(default)]
    pub after_key: Option<ListKey>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing: Vec<ListKey>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unknown: Vec<ListKey>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rest: Vec<ListKey>,
}

/// A bounded window on the folders view. It is separate from `Window<T>` so
/// older clients can continue decoding summary list windows unchanged.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderWindow {
    pub sid: String,
    pub cursor: u64,
    pub rows: Vec<FolderRow>,
    pub has_before: bool,
    pub has_after: bool,
    #[serde(default)]
    pub edition: u32,
    #[serde(default)]
    pub origins: Vec<Origin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before_key: Option<FolderPosition>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after_key: Option<FolderPosition>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FolderPageResult {
    pub sid: String,
    pub rows: Vec<FolderRow>,
    pub has_before: bool,
    pub has_after: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cold_unread: bool,
    #[serde(default)]
    pub before_key: Option<FolderPosition>,
    #[serde(default)]
    pub after_key: Option<FolderPosition>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing: Vec<FolderIdentity>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rest: Vec<FolderIdentity>,
}

/// JSON bytes carried as they are stored: a chat row's text, or an escaped `text` piece.
/// They are copied into a frame and never parsed into values and escaped again.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RawJson(pub Box<serde_json::value::RawValue>);

impl RawJson {
    /// Takes stored JSON bytes. The bytes are checked once, here.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, FrameError> {
        let text = std::str::from_utf8(bytes).map_err(|_| {
            FrameError::Encode(serde_json::Error::custom("stored JSON is not UTF-8"))
        })?;
        serde_json::value::RawValue::from_string(text.to_owned())
            .map(Self)
            .map_err(FrameError::Encode)
    }

    pub fn get(&self) -> &str {
        self.0.get()
    }
}

impl PartialEq for RawJson {
    fn eq(&self, other: &Self) -> bool {
        self.get() == other.get()
    }
}

impl Eq for RawJson {}

/// A waiting prompt as a window and a `queue` op carry it: its id, at most 1 KB of its text,
/// and the text's whole length. The rest of the text is read by `blob`.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueItem {
    pub id: String,
    pub text: String,
    /// The decoded text's length in bytes.
    pub len: u64,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub held: bool,
    pub at: u64,
}

/// The entries next to run (at most 64) and the count of all that wait.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueHead {
    pub entries: Vec<QueueItem>,
    pub count: u32,
}

/// An open row as a window or a resume's state frame carries it. `row` holds the body while
/// the open bodies fit in 64 KB together; past that the body is left out (`{}`) and `bodyLen`
/// names its length, read by `blob`.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenRow {
    pub row: RawJson,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body_len: Option<u64>,
}

/// A chat's window: the breakpoint everything after it is a delta of. Separate from
/// `Window<T>` so the list's clients decode their windows unchanged.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatWindow {
    pub sid: String,
    pub cursor: u64,
    pub edition: u32,
    pub rows: Vec<RawJson>,
    pub has_before: bool,
    pub has_after: bool,
    #[serde(default)]
    pub open: Vec<OpenRow>,
    #[serde(default)]
    pub queue: QueueHead,
    /// The person's seen row.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen: Option<u64>,
    /// The person's open folds.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub folds: Vec<u64>,
    /// Rows this window would hold whose records a read refused.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub refused: Vec<u64>,
}

/// A chat's page reply. `refused` names the rows in its range whose records were refused.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatPageResult {
    pub sid: String,
    pub edition: u32,
    pub rows: Vec<RawJson>,
    pub has_before: bool,
    pub has_after: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub refused: Vec<u64>,
}

/// One op of a chat's delta. A settled row and a patch carry a seq of their own; a row that
/// begins, a `text` and a `queue` op carry the last record's seq and move no cursor. Separate
/// from the list's `DeltaOp<T>`, in the same frame kind.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "op")]
pub enum ChatOp {
    /// A settled row, or an open one as it is now; it replaces what the client holds for its
    /// rowId. An open row whose body was left out names its length, read by `blob`.
    Row {
        seq: u64,
        row: RawJson,
        #[serde(skip_serializing_if = "Option::is_none")]
        body_len: Option<u64>,
    },
    /// Text appended to an open row's `text`: an escaped JSON string, as stored.
    Text { seq: u64, row_id: u64, text: RawJson },
    /// A new rev of a settled row.
    Patch { seq: u64, row: RawJson },
    /// One entry as it is now, or its removal, with the count; or `head`, the entries next to
    /// run, which replaces what the client holds.
    Queue {
        seq: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        entry: Option<QueueItem>,
        #[serde(skip_serializing_if = "Option::is_none")]
        removed: Option<String>,
        count: u32,
        #[serde(skip_serializing_if = "Option::is_none")]
        head: Option<QueueHead>,
    },
}

// Read from the JSON map directly, as `DeltaOp` is: an internally tagged enum buffers its
// fields, which a `RawJson` cannot come through.
impl<'de> Deserialize<'de> for ChatOp {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Fields {
            op: String,
            seq: u64,
            row: Option<RawJson>,
            body_len: Option<u64>,
            row_id: Option<u64>,
            text: Option<RawJson>,
            entry: Option<QueueItem>,
            removed: Option<String>,
            count: Option<u32>,
            head: Option<QueueHead>,
        }
        let fields = Fields::deserialize(deserializer)?;
        let seq = fields.seq;
        match fields.op.as_str() {
            "row" => Ok(Self::Row {
                seq,
                row: fields.row.ok_or_else(|| D::Error::missing_field("row"))?,
                body_len: fields.body_len,
            }),
            "text" => Ok(Self::Text {
                seq,
                row_id: fields.row_id.ok_or_else(|| D::Error::missing_field("rowId"))?,
                text: fields.text.ok_or_else(|| D::Error::missing_field("text"))?,
            }),
            "patch" => Ok(Self::Patch {
                seq,
                row: fields.row.ok_or_else(|| D::Error::missing_field("row"))?,
            }),
            "queue" => Ok(Self::Queue {
                seq,
                entry: fields.entry,
                removed: fields.removed,
                count: fields.count.ok_or_else(|| D::Error::missing_field("count"))?,
                head: fields.head,
            }),
            other => Err(D::Error::unknown_variant(other, &["row", "text", "patch", "queue"])),
        }
    }
}

/// A chat's delta frame: `{sid, replay?, ops}`. A resume's frames set `replay`; its last, the
/// state frame, is `"end"`.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatDelta {
    pub sid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay: Option<ReplayMark>,
    pub ops: Vec<ChatOp>,
}

/// A bounded read of a row's body, or of a waiting prompt's text.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Blob {
    /// The request's id, named again by its reply.
    pub id: String,
    pub stream: Stream,
    pub edition: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row_id: Option<u64>,
    /// A waiting prompt's id, in place of `rowId`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    /// The range's start; for a prompt with `from` and no start, the token's offset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<u64>,
    pub len: u64,
    /// A prompt's `next` token: where the scan starts, never where the bytes start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
}

/// The JSON head of a `blob` reply. The frame is this head, a newline, then the bytes.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BlobHead {
    pub id: String,
    pub start: u64,
    pub len: u64,
    /// The body's (or the prompt text's) whole length.
    pub total: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<String>,
    /// An open row's snapshot: `gen` names it and the bytes under `fixed` stay within it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub open: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "gen")]
    pub generation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fixed: Option<u64>,
}

/// A `blob` reply: the head, a newline, the bytes as they are stored.
pub fn blob_frame(head: &BlobHead, bytes: &[u8]) -> Result<Frame, FrameError> {
    let mut payload = serde_json::to_vec(head).map_err(FrameError::Encode)?;
    payload.reserve(1 + bytes.len());
    payload.push(b'\n');
    payload.extend_from_slice(bytes);
    Frame::new(FrameKind::Blob, payload)
}

/// Splits a `blob` reply into its head and its bytes.
pub fn decode_blob(frame: &Frame) -> Result<(BlobHead, &[u8]), FrameError> {
    let payload = frame.payload();
    let newline = payload.iter().position(|byte| *byte == b'\n').ok_or(FrameError::Truncated)?;
    let (head, rest) = payload.split_at(newline);
    let head = serde_json::from_slice(head).map_err(FrameError::Decode)?;
    Ok((head, rest.get(1..).unwrap_or_default()))
}

/// One bounded delta frame. Resume frames carry at most 256 KiB of operations;
/// the final frame has `replay: "end"` and may contain no operations.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeltaFrame<T> {
    pub sid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay: Option<ReplayMark>,
    pub ops: Vec<DeltaOp<T>>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "op")]
pub enum DeltaOp<T> {
    Summary {
        seq: u64,
        summary: T,
    },
    Gone {
        seq: u64,
        origin: String,
        chat_id: String,
    },
    Queue {
        seq: u64,
        bytes: u64,
    },
    Origin {
        seq: u64,
        #[serde(flatten)]
        origin: Origin,
    },
    #[serde(rename = "folder")]
    Folder {
        seq: u64,
        row: FolderRow,
    },
    #[serde(rename = "folderGone")]
    FolderGone {
        seq: u64,
        origin: String,
        folder: String,
    },
}

// Deserialize fields directly from the JSON map. Serde's internally tagged
// enum buffers the map as Content, which cannot preserve Summary.extra's
// RawValue. This keeps opaque extension bytes on the original JSON decoder.
impl<'de, T: Deserialize<'de>> Deserialize<'de> for DeltaOp<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", bound(deserialize = "T: Deserialize<'de>"))]
        struct Fields<T> {
            op: String,
            seq: u64,
            summary: Option<T>,
            chat_id: Option<String>,
            origin: Option<String>,
            bytes: Option<u64>,
            id: Option<String>,
            state: Option<OriginState>,
            since: Option<u64>,
            extra: Option<serde_json::Value>,
            row: Option<FolderRow>,
            folder: Option<String>,
        }
        let fields = Fields::<T>::deserialize(deserializer)?;
        match fields.op.as_str() {
            "summary" => Ok(Self::Summary {
                seq: fields.seq,
                summary: fields.summary.ok_or_else(|| D::Error::missing_field("summary"))?,
            }),
            "gone" => Ok(Self::Gone {
                seq: fields.seq,
                origin: fields.origin.ok_or_else(|| D::Error::missing_field("origin"))?,
                chat_id: fields.chat_id.ok_or_else(|| D::Error::missing_field("chatId"))?,
            }),
            "queue" => Ok(Self::Queue {
                seq: fields.seq,
                bytes: fields.bytes.ok_or_else(|| D::Error::missing_field("bytes"))?,
            }),
            "origin" => Ok(Self::Origin {
                seq: fields.seq,
                origin: Origin {
                    id: fields.id.ok_or_else(|| D::Error::missing_field("id"))?,
                    state: fields.state.ok_or_else(|| D::Error::missing_field("state"))?,
                    since: fields.since.ok_or_else(|| D::Error::missing_field("since"))?,
                    extra: fields.extra,
                },
            }),
            "folder" => Ok(Self::Folder {
                seq: fields.seq,
                row: fields.row.ok_or_else(|| D::Error::missing_field("row"))?,
            }),
            "folderGone" => Ok(Self::FolderGone {
                seq: fields.seq,
                origin: fields.origin.ok_or_else(|| D::Error::missing_field("origin"))?,
                folder: fields.folder.ok_or_else(|| D::Error::missing_field("folder"))?,
            }),
            other => Err(D::Error::unknown_variant(
                other,
                &["summary", "gone", "queue", "origin", "folder", "folderGone"],
            )),
        }
    }
}

pub fn delta_frame<T: Serialize>(delta: &DeltaFrame<T>) -> Result<Frame, FrameError> {
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
    Request = 9,
    Unknown(u8),
}

impl TryFrom<u8> for FrameKind {
    type Error = FrameError;

    fn try_from(value: u8) -> Result<Self, FrameError> {
        match value {
            1 => Ok(Self::Hello),
            2 => Ok(Self::Window),
            3 => Ok(Self::Delta),
            4 => Ok(Self::Page),
            5 => Ok(Self::Blob),
            6 => Ok(Self::Ack),
            7 => Ok(Self::Dropped),
            8 => Ok(Self::Error),
            9 => Ok(Self::Request),
            _ => Ok(Self::Unknown(value)),
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
        out.push(match self.kind {
            FrameKind::Hello => 1,
            FrameKind::Window => 2,
            FrameKind::Delta => 3,
            FrameKind::Page => 4,
            FrameKind::Blob => 5,
            FrameKind::Ack => 6,
            FrameKind::Dropped => 7,
            FrameKind::Error => 8,
            FrameKind::Request => 9,
            FrameKind::Unknown(kind) => kind,
        });
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
            let body = self
                .bytes
                .get(self.head..self.head + expected)
                .ok_or(FrameError::Truncated)?
                .to_vec();
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
    TooLarge {
        bytes: usize,
    },
    InvalidLength(usize),
    UnknownKind(u8),
    Truncated,
    TrailingBytes,
    Encode(serde_json::Error),
    Decode(serde_json::Error),
    RequestInFlight,
    MirrorUnsupported,
    /// A request the client core does not send, and why.
    Refused(&'static str),
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
            Self::RequestInFlight => f.write_str("a page request is already in flight"),
            Self::MirrorUnsupported => f.write_str("folders view cannot be mirrored"),
            Self::Refused(why) => write!(f, "refused: {why}"),
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
    fn old_page_results_default_cold_unread_and_false_stays_off_wire() {
        let old = serde_json::json!({"sid":"s","rows":[],"hasBefore":false,"hasAfter":false});
        let page: PageResult<serde_json::Value> = serde_json::from_value(old).unwrap();
        assert!(!page.cold_unread);
        assert!(serde_json::to_value(page).unwrap().get("coldUnread").is_none());
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

#[cfg(test)]
mod raw_delta_tests {
    use super::*;
    use acpmux_list_types::Summary;

    #[test]
    fn summary_delta_preserves_opaque_json_bytes() {
        let raw = r#"{ "opaque" : [1,  2], "text": "\u0061" }"#;
        let mut summary = Summary::new("raw");
        summary.extra = serde_json::value::RawValue::from_string(raw.into()).unwrap();
        let frame = delta_frame(&DeltaFrame {
            sid: "s".into(),
            replay: Some(ReplayMark::End),
            ops: vec![DeltaOp::Summary { seq: 1, summary }],
        })
        .unwrap();
        let decoded: DeltaFrame<Summary> = frame.decode_json().unwrap();
        let Some(DeltaOp::Summary { summary, .. }) = decoded.ops.first() else {
            panic!("missing summary")
        };
        assert_eq!(summary.extra.get(), raw);
    }
}

#[cfg(test)]
mod other_delta_tests {
    use super::*;
    use acpmux_list_types::RowKey;
    use acpmux_list_types::folders::FolderRow;

    #[test]
    fn every_delta_op_has_one_round_tripping_shape() {
        let ops = vec![
            DeltaOp::<serde_json::Value>::Gone {
                seq: 1,
                origin: "local".into(),
                chat_id: "gone".into(),
            },
            DeltaOp::Queue { seq: 2, bytes: 3 },
            DeltaOp::Origin {
                seq: 3,
                origin: Origin {
                    id: "peer".into(),
                    state: OriginState::Down,
                    since: 4,
                    extra: None,
                },
            },
        ];
        let frame = delta_frame(&DeltaFrame {
            sid: "s".into(),
            replay: Some(ReplayMark::End),
            ops: ops.clone(),
        })
        .unwrap();
        let decoded: DeltaFrame<serde_json::Value> = frame.decode_json().unwrap();
        assert_eq!(decoded.ops, ops);
    }

    #[test]
    fn folders_view_and_deltas_round_trip() {
        let row = FolderRow {
            origin: "local".into(),
            folder: "/work".into(),
            newest: RowKey::new("local", "chat-7"),
            at: 19,
            count: 3,
        };
        let request = Sub { view: Some(ListView::Folders), ..Sub::new("s", "list") };
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value.get("view"), Some(&serde_json::json!("folders")));
        assert!(validate_mirror_view(Some(ListView::Folders)).is_err());

        let ops = vec![
            DeltaOp::<serde_json::Value>::Folder { seq: 4, row },
            DeltaOp::FolderGone { seq: 5, origin: "local".into(), folder: "/work".into() },
        ];
        let frame = delta_frame(&DeltaFrame {
            sid: "s".into(),
            replay: Some(ReplayMark::End),
            ops: ops.clone(),
        })
        .unwrap();
        let decoded: DeltaFrame<serde_json::Value> = frame.decode_json().unwrap();
        assert_eq!(decoded.ops, ops);
    }

    #[test]
    fn chat_ops_round_trip_in_their_own_delta() {
        let row = RawJson::from_bytes(br#"{"id":7,"rev":1,"body":{"text":"a\"b"}}"#).unwrap();
        let item = QueueItem { id: "p".into(), text: "hi".into(), len: 2, held: false, at: 9 };
        let ops = vec![
            ChatOp::Row { seq: 3, row: row.clone(), body_len: Some(9) },
            ChatOp::Text {
                seq: 3,
                row_id: 7,
                text: RawJson::from_bytes(br#""\n\u0001""#).unwrap(),
            },
            ChatOp::Patch { seq: 4, row },
            ChatOp::Queue {
                seq: 4,
                entry: Some(item.clone()),
                removed: None,
                count: 1,
                head: None,
            },
            ChatOp::Queue { seq: 4, entry: None, removed: Some("q".into()), count: 0, head: None },
            ChatOp::Queue {
                seq: 4,
                entry: None,
                removed: None,
                count: 1,
                head: Some(QueueHead { entries: vec![item], count: 1 }),
            },
        ];
        let delta = ChatDelta { sid: "s".into(), replay: Some(ReplayMark::End), ops };
        let frame = Frame::json(FrameKind::Delta, &delta).unwrap();
        // Stored bytes go out as they are: the escape is not decoded and escaped again.
        assert!(std::str::from_utf8(frame.payload()).unwrap().contains(r#""a\"b""#));
        let decoded: ChatDelta = frame.decode_json().unwrap();
        assert_eq!(decoded, delta);
    }

    #[test]
    fn a_blob_reply_is_a_head_a_newline_and_the_stored_bytes() {
        let head = BlobHead {
            id: "b".into(),
            start: 4,
            len: 3,
            total: 10,
            next: None,
            open: true,
            generation: Some("0123456789abcdef".into()),
            fixed: Some(8),
        };
        let frame = blob_frame(&head, b"\\\"\n").unwrap();
        assert_eq!(frame.kind, FrameKind::Blob);
        let (decoded, bytes) = decode_blob(&frame).unwrap();
        assert_eq!(decoded, head);
        assert_eq!(bytes, b"\\\"\n");
        let request: Request = serde_json::from_value(serde_json::json!({
            "method": "blob",
            "params": {"id": "b", "stream": "chat:c", "edition": 2, "rowId": 7, "len": 10}
        }))
        .unwrap();
        assert!(matches!(request, Request::Blob(Blob { row_id: Some(7), .. })));
    }

    #[test]
    fn folder_position_keeps_a_full_bound_sized_name() {
        let key = FolderPosition { at: 7, origin: "o".into(), folder: "x".repeat(1024) };
        let value = serde_json::to_value(&key).unwrap();
        let decoded: FolderPosition = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, key);
    }

    #[test]
    fn keyed_summary_pages_keep_the_old_json_shape() {
        let page = serde_json::json!({
            "sid":"s", "stream":"list", "keys":[{"lastActivity":4,"chatId":"c","origin":"local"}]
        });
        let decoded: Page = serde_json::from_value(page).unwrap();
        assert!(matches!(decoded.keys.as_deref(), Some([PageKey::Summary(_)])));
        let legacy =
            vec![ListKey { last_activity: 4, chat_id: "c".into(), origin: "local".into() }];
        assert_eq!(
            serde_json::to_vec(decoded.keys.as_ref().unwrap()).unwrap(),
            serde_json::to_vec(&legacy).unwrap(),
            "summary keys retain their pre-folders wire bytes"
        );
    }
}
