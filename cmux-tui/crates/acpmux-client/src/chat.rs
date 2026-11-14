//! A chat's subscriptions, on the same client a list's live on.
//!
//! For each chat sub the core holds its sid, cursor, edition and resume state, and no row: a row
//! goes from the frame to the change as the bytes it arrived in, never parsed and never encoded
//! again. The caller keeps the rows and nothing of the wire: the window says whether it replaces
//! the rows held or adds to them, so no caller compares an edition.

use crate::wire::{
    self, Anchor, Blob, BlobHead, ChatOp, ChatPageResult, ChatWindow, Cursor, Frame, FrameError,
    FrameKind, Page, PageSide, RawJson, Request, Sub,
};
use crate::{Change, Client, Phase};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::value::RawValue;

/// The most rows a chat's window or page holds, a refused row counted as one.
pub const MAX_CHAT_ROWS: usize = 400;
/// The most `blob` requests one handle holds unanswered.
pub const MAX_PENDING_BLOBS: usize = 64;

/// A chat stream's change. None depends on the list's row type.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all_fields = "camelCase")]
pub enum ChatChange {
    /// `replaces`: the rows the caller holds for this chat go (the sub's first window, or one of
    /// another edition). Otherwise the window adds to them, and each row held outside it is
    /// unconfirmed until a page covers it.
    #[serde(rename = "chatWindow")]
    Window { replaces: bool, window: ChatWindow },
    /// One op of a delta. `replay`: the frame was a resume's, so the op is drawn settled and is
    /// held until the resume ends.
    #[serde(rename = "chatOp")]
    Op { sid: String, replay: bool, op: ChatOp },
    /// The resume ended: by its `end` frame, or by a window that came in its place, which follows.
    #[serde(rename = "chatResumeEnd")]
    ResumeEnd { sid: String, cursor: u64 },
    #[serde(rename = "chatPage")]
    Page { page: ChatPageResult },
    /// A blob reply cut to its last whole character (and, in a row's body, its last whole JSON
    /// escape). `nextStart` is where the next range starts; the bytes follow the JSON.
    #[serde(rename = "chatBlob")]
    Blob {
        sid: String,
        head: BlobHead,
        next_start: u64,
        #[serde(skip)]
        bytes: Vec<u8>,
    },
    /// The daemon dropped the sub; the core subscribed again under the same sid.
    #[serde(rename = "chatDropped")]
    Dropped { sid: String, cursor: Option<u64> },
    #[serde(rename = "chatError")]
    Error { sid: Option<String>, method: String, id: Option<String>, code: String },
}

/// `subscribe_chat`'s request: a chat, opened at `end` or around a rowId, with `window` rows.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatSubRequest {
    pub sid: String,
    pub chat: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor: Option<Anchor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<u16>,
}

/// `chat_page`'s request: before or after a rowId, and a fold to read as open.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatPageRequest {
    pub sid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fold: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_bytes: Option<u32>,
}

/// `chat_blob`'s request: a row's body or a waiting prompt's text, and a range of it.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatBlobRequest {
    pub sid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row_id: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<u64>,
    pub len: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct ChatSub {
    initial: Sub,
    request: Sub,
    cursor: Cursor,
    /// The edition of the last window; none until the first.
    edition: Option<u32>,
    replaying: bool,
    pub(crate) consumed: u64,
    pub(crate) credited: u64,
    page: Option<Page>,
}

impl ChatSub {
    /// What a reconnect or a drop sends: the cursor and edition once a window was taken, else
    /// the first request again.
    fn resume(&mut self) {
        if let Some(edition) = self.edition {
            self.request = self.initial.clone().from_cursor_in_edition(self.cursor, edition);
            self.replaying = true;
        } else {
            self.request = self.initial.clone();
            self.replaying = false;
        }
        self.consumed = 0;
        self.credited = 0;
    }

    fn advance(&mut self, seq: u64) {
        if seq > self.cursor.0 {
            self.cursor = Cursor(seq);
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct PendingBlob {
    sid: String,
    request: Blob,
}

#[derive(Deserialize)]
struct Hint {
    #[serde(default)]
    sid: Option<String>,
    #[serde(default)]
    id: Option<String>,
}

/// A delta whose ops are kept as their bytes until each is read, so one op the core does not know
/// is skipped and the others are not.
#[derive(Deserialize)]
struct RawDelta {
    sid: String,
    #[serde(default)]
    replay: Option<String>,
    ops: Vec<Box<RawValue>>,
}

#[derive(Deserialize)]
struct OpSeq {
    #[serde(default)]
    seq: Option<u64>,
}

#[derive(Deserialize)]
struct ErrorFrame {
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    sid: Option<String>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    code: Option<String>,
}

fn over_bound(rows: &[RawJson], refused: usize) -> bool {
    rows.len().saturating_add(refused) > MAX_CHAT_ROWS
        || rows.iter().map(|row| row.get().len()).sum::<usize>() > wire::MAX_PAGE_BYTES
}

/// The length of `bytes` that ends on a whole UTF-8 character.
fn whole_chars(bytes: &[u8]) -> usize {
    let len = bytes.len();
    for back in 1..=len.min(4) {
        let at = len - back;
        let byte = bytes.get(at).copied().unwrap_or_default();
        if byte & 0xc0 == 0x80 {
            continue;
        }
        let width = match byte {
            0x00..=0x7f => 1,
            0xc0..=0xdf => 2,
            0xe0..=0xef => 3,
            _ => 4,
        };
        return if back < width { at } else { len };
    }
    len
}

/// Where an escape that `bytes` does not finish starts: a `\` alone, a `\u` short of its four
/// digits, or a high surrogate with no low one after it. A range starts on an escape's
/// boundary (the reader joins ranges from the body's start), so the run of `\` is counted from
/// the range's start.
fn open_escape(bytes: &[u8]) -> Option<usize> {
    // An escape is at most 12 bytes: a surrogate pair, `😀`.
    let tail = bytes.len().saturating_sub(12);
    let last = tail + bytes.get(tail..)?.iter().rposition(|byte| *byte == b'\\')?;
    let run = bytes.get(..last)?.iter().rev().take_while(|byte| **byte == b'\\').count();
    if run % 2 == 1 {
        // The second `\` of `\\`: a whole escape.
        return None;
    }
    let escape = bytes.get(last..)?;
    match escape.get(1) {
        None => Some(last),
        Some(b'u') => {
            let Some(digits) = escape.get(2..6) else { return Some(last) };
            let code = std::str::from_utf8(digits)
                .ok()
                .and_then(|hex| u16::from_str_radix(hex, 16).ok())?;
            // A high surrogate is half a character until its low one follows.
            ((0xd800..0xdc00).contains(&code) && escape.len() == 6).then_some(last)
        }
        Some(_) => None,
    }
}

/// The length of a row body's bytes that ends on a whole character and a whole JSON escape.
fn whole_body_prefix(bytes: &[u8]) -> usize {
    let mut end = whole_chars(bytes);
    while let Some(start) = bytes.get(..end).and_then(open_escape) {
        end = start;
    }
    end
}

impl<T> Client<T>
where
    T: Serialize + DeserializeOwned + Clone,
{
    /// Subscribes a chat on this handle. The sid is the caller's name for it from here on; a
    /// drop subscribes again under the same sid.
    pub fn subscribe_chat(&mut self, request: ChatSubRequest) -> Result<String, FrameError> {
        let ChatSubRequest { sid, chat, anchor, window } = request;
        if !wire::identifier_fits(&sid) {
            return Err(FrameError::InvalidLength(sid.len()));
        }
        if !wire::identifier_fits(&chat) {
            return Err(FrameError::InvalidLength(chat.len()));
        }
        if self.subscriptions.contains_key(&sid) || self.chats.contains_key(&sid) {
            return Err(FrameError::Refused("the sid is held"));
        }
        if self.subscriptions.len().saturating_add(self.chats.len()) >= wire::MAX_SUBSCRIPTIONS {
            return Err(FrameError::Refused("a handle holds at most 256 subscriptions"));
        }
        let anchor = anchor.unwrap_or(Anchor::End);
        if matches!(anchor, Anchor::List { .. }) {
            return Err(FrameError::Refused("a chat opens at end or at a rowId"));
        }
        let window = window.unwrap_or(100).clamp(1, MAX_CHAT_ROWS as u16);
        let sub = Sub::new(sid.clone(), format!("chat:{chat}")).around(anchor, window);
        Frame::json(FrameKind::Request, &Request::Sub(sub.clone()))?;
        self.chats.insert(
            sid.clone(),
            ChatSub {
                initial: sub.clone(),
                request: sub.clone(),
                cursor: Cursor::default(),
                edition: None,
                replaying: false,
                consumed: 0,
                credited: 0,
                page: None,
            },
        );
        if self.phase == Phase::Ready {
            self.queue_request(Request::Sub(sub))?;
        }
        Ok(sid)
    }

    /// Asks a chat sub for a page. The core fills the stream and the edition; one page per sub
    /// is out at a time.
    pub fn chat_page(&mut self, request: ChatPageRequest) -> Result<(), FrameError> {
        let Some(chat) = self.chats.get_mut(&request.sid) else {
            return Err(FrameError::Refused("no chat sub has this sid"));
        };
        let Some(edition) = chat.edition else {
            return Err(FrameError::Refused("a chat sub pages after its first window"));
        };
        if chat.page.is_some() {
            return Err(FrameError::RequestInFlight);
        }
        let (side, row_id) = match (request.before, request.after) {
            (Some(row_id), None) => (PageSide::Before, row_id),
            (None, Some(row_id)) => (PageSide::After, row_id),
            _ => return Err(FrameError::Refused("a page names before or after")),
        };
        let mut page = Page::new(request.sid, chat.request.stream.clone(), side, row_id);
        page.edition = Some(edition);
        page.fold = request.fold;
        if let Some(max_bytes) = request.max_bytes {
            page.max_bytes = max_bytes.min(wire::MAX_PAGE_BYTES as u32);
        }
        chat.page = Some(page.clone());
        if self.phase == Phase::Ready {
            self.queue_request(Request::Page(page))?;
        }
        Ok(())
    }

    /// Asks for a range of a row's body or of a waiting prompt's text, and gives the request's
    /// id, which its reply names.
    pub fn chat_blob(&mut self, request: ChatBlobRequest) -> Result<String, FrameError> {
        let Some(chat) = self.chats.get(&request.sid) else {
            return Err(FrameError::Refused("no chat sub has this sid"));
        };
        let Some(edition) = chat.edition else {
            return Err(FrameError::Refused("a chat sub reads blobs after its first window"));
        };
        if request.row_id.is_some() == request.prompt.is_some() {
            return Err(FrameError::Refused("a blob names a rowId or a prompt"));
        }
        for name in [&request.prompt, &request.from].into_iter().flatten() {
            if !wire::identifier_fits(name) {
                return Err(FrameError::InvalidLength(name.len()));
            }
        }
        if self.blobs.len() >= MAX_PENDING_BLOBS {
            return Err(FrameError::Refused("a handle holds at most 64 blob requests"));
        }
        let id = format!("b{}", self.next_id);
        self.next_id = self.next_id.saturating_add(1);
        let blob = Blob {
            id: id.clone(),
            stream: chat.request.stream.clone(),
            edition,
            row_id: request.row_id,
            prompt: request.prompt,
            start: request.start,
            len: request.len,
            from: request.from,
        };
        self.blobs.push_back(PendingBlob { sid: request.sid, request: blob.clone() });
        if self.phase == Phase::Ready {
            self.queue_request(Request::Blob(blob))?;
        }
        Ok(id)
    }

    pub(crate) fn forget_chat(&mut self, sid: &str) -> bool {
        self.blobs.retain(|blob| blob.sid != sid);
        self.chats.remove(sid).is_some()
    }

    pub(crate) fn chats_disconnected(&mut self) {
        for chat in self.chats.values_mut() {
            chat.resume();
        }
    }

    /// After `hello`: each chat sub, then the pages and blobs that were out.
    pub(crate) fn queue_chat_requests(&mut self) {
        let subs: Vec<Sub> = self.chats.values().map(|chat| chat.request.clone()).collect();
        let pages: Vec<Page> = self.chats.values().filter_map(|chat| chat.page.clone()).collect();
        let blobs: Vec<Blob> = self.blobs.iter().map(|blob| blob.request.clone()).collect();
        for sub in subs {
            let _ = self.queue_request(Request::Sub(sub));
        }
        for page in pages {
            let _ = self.queue_request(Request::Page(page));
        }
        for blob in blobs {
            let _ = self.queue_request(Request::Blob(blob));
        }
    }

    pub(crate) fn chat_credit(&mut self, sid: &str) -> Option<(&mut u64, &mut u64)> {
        self.chats.get_mut(sid).map(|chat| (&mut chat.consumed, &mut chat.credited))
    }

    /// Takes a frame of a chat sub or a blob; gives back every other frame for the list.
    pub(crate) fn accept_chat_frame(&mut self, frame: Frame, frame_bytes: u64) -> Option<Frame> {
        if frame.kind == FrameKind::Blob {
            self.accept_blob(&frame, frame_bytes);
            return None;
        }
        if self.chats.is_empty() && self.blobs.is_empty() {
            return Some(frame);
        }
        if !matches!(
            frame.kind,
            FrameKind::Window
                | FrameKind::Page
                | FrameKind::Delta
                | FrameKind::Dropped
                | FrameKind::Error
        ) {
            return Some(frame);
        }
        let Ok(hint) = frame.decode_json::<Hint>() else { return Some(frame) };
        let chat = hint.sid.as_deref().is_some_and(|sid| self.chats.contains_key(sid));
        let blob = frame.kind == FrameKind::Error
            && hint.id.as_deref().is_some_and(|id| self.blobs.iter().any(|b| b.request.id == id));
        if !chat && !blob {
            return Some(frame);
        }
        match frame.kind {
            FrameKind::Window => self.accept_chat_window(&frame, frame_bytes),
            FrameKind::Page => self.accept_chat_page(&frame, frame_bytes),
            FrameKind::Delta => self.accept_chat_delta(&frame, frame_bytes),
            FrameKind::Dropped => self.accept_chat_dropped(&frame),
            _ => self.accept_chat_error(&frame, frame_bytes),
        }
        None
    }

    fn refuse_over_bound(&mut self, sid: &str, method: &str, frame_bytes: u64) {
        self.skips.over_bound = self.skips.over_bound.saturating_add(1);
        self.charge_frame_now(Some(sid), frame_bytes);
        self.push_change(
            Change::Chat(ChatChange::Error {
                sid: Some(sid.to_owned()),
                method: method.to_owned(),
                id: None,
                code: "over_bound".into(),
            }),
            None,
            0,
            false,
        );
    }

    fn accept_chat_window(&mut self, frame: &Frame, frame_bytes: u64) {
        let Ok(window) = frame.decode_json::<ChatWindow>() else {
            self.protocol_error("malformed chat window");
            return;
        };
        let sid = window.sid.clone();
        if over_bound(&window.rows, window.refused.len()) {
            self.refuse_over_bound(&sid, "sub", frame_bytes);
            return;
        }
        let Some(chat) = self.chats.get_mut(&sid) else { return };
        let ended = chat.replaying.then_some(chat.cursor.0);
        let replaces = chat.edition != Some(window.edition);
        chat.cursor = Cursor(window.cursor);
        chat.edition = Some(window.edition);
        chat.replaying = false;
        if let Some(cursor) = ended {
            // A window in place of a resume's end ends the resume: the frames held, then this.
            self.push_change(
                Change::Chat(ChatChange::ResumeEnd { sid: sid.clone(), cursor }),
                None,
                0,
                false,
            );
        }
        self.push_change(
            Change::Chat(ChatChange::Window { replaces, window }),
            Some(sid),
            frame_bytes,
            true,
        );
    }

    fn accept_chat_page(&mut self, frame: &Frame, frame_bytes: u64) {
        let Ok(page) = frame.decode_json::<ChatPageResult>() else {
            self.protocol_error("malformed chat page");
            return;
        };
        let sid = page.sid.clone();
        if self.chats.get_mut(&sid).and_then(|chat| chat.page.take()).is_none() {
            // A reply to no page out on this connection.
            self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
            self.charge_frame_now(Some(&sid), frame_bytes);
            return;
        }
        if over_bound(&page.rows, page.refused.len()) {
            self.refuse_over_bound(&sid, "page", frame_bytes);
            return;
        }
        self.push_change(Change::Chat(ChatChange::Page { page }), Some(sid), frame_bytes, true);
    }

    fn accept_chat_delta(&mut self, frame: &Frame, frame_bytes: u64) {
        let Ok(delta) = frame.decode_json::<RawDelta>() else {
            self.protocol_error("malformed delta");
            return;
        };
        let replay = match delta.replay.as_deref() {
            None => false,
            Some("replay" | "end") => true,
            Some(_) => {
                self.protocol_error("invalid replay mark");
                return;
            }
        };
        let end = delta.replay.as_deref() == Some("end");
        let sid = delta.sid;
        let Some(chat) = self.chats.get_mut(&sid) else { return };
        if replay {
            chat.replaying = true;
        }
        let mut charged = false;
        for raw in delta.ops {
            match serde_json::from_str::<ChatOp>(raw.get()) {
                Ok(op) => {
                    // Only a settled row and a patch carry a seq of their own. A row that begins
                    // carries the last record's, which the cursor already is at.
                    if let ChatOp::Row { seq, .. } | ChatOp::Patch { seq, .. } = &op
                        && let Some(chat) = self.chats.get_mut(&sid)
                    {
                        chat.advance(*seq);
                    }
                    let charge = !charged;
                    charged = true;
                    self.push_change(
                        Change::Chat(ChatChange::Op { sid: sid.clone(), replay, op }),
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                Err(_) => match serde_json::from_str::<OpSeq>(raw.get()).ok().and_then(|o| o.seq) {
                    None => self.skips.missing_seq = self.skips.missing_seq.saturating_add(1),
                    Some(seq) => {
                        self.skips.unknown_op = self.skips.unknown_op.saturating_add(1);
                        if let Some(chat) = self.chats.get_mut(&sid) {
                            chat.advance(seq);
                        }
                    }
                },
            }
        }
        if !charged {
            self.charge_frame_now(Some(&sid), frame_bytes);
        }
        if end && let Some(chat) = self.chats.get_mut(&sid) {
            chat.replaying = false;
            let cursor = chat.cursor.0;
            self.push_change(Change::Chat(ChatChange::ResumeEnd { sid, cursor }), None, 0, false);
        }
    }

    fn accept_chat_dropped(&mut self, frame: &Frame) {
        let Ok(drop) = frame.decode_json::<wire::Dropped>() else {
            self.protocol_error("malformed dropped");
            return;
        };
        let Some(chat) = self.chats.get_mut(&drop.sid) else { return };
        // The sid is free once its notice is written, so the sub takes it again. A page or a
        // blob that was out is asked again; a reply that still comes for the first is skipped.
        chat.resume();
        let mut requests = vec![Request::Sub(chat.request.clone())];
        requests.extend(chat.page.clone().map(Request::Page));
        requests.extend(
            self.blobs
                .iter()
                .filter(|blob| blob.sid == drop.sid)
                .map(|blob| Request::Blob(blob.request.clone())),
        );
        if self.phase == Phase::Ready {
            for request in requests {
                let _ = self.queue_request(request);
            }
        }
        self.push_change(
            Change::Chat(ChatChange::Dropped { sid: drop.sid, cursor: drop.cursor.map(|c| c.0) }),
            None,
            0,
            false,
        );
    }

    fn accept_chat_error(&mut self, frame: &Frame, frame_bytes: u64) {
        let Ok(error) = frame.decode_json::<ErrorFrame>() else {
            self.protocol_error("malformed error");
            return;
        };
        let method = error.method.unwrap_or_else(|| "unknown".into());
        let code = error.code.unwrap_or_else(|| "error".into());
        let mut sid = error.sid.filter(|sid| self.chats.contains_key(sid));
        match method.as_str() {
            "blob" => {
                if let Some(at) = error
                    .id
                    .as_deref()
                    .and_then(|id| self.blobs.iter().position(|b| b.request.id == id))
                    && let Some(blob) = self.blobs.remove(at)
                {
                    sid = Some(blob.sid);
                }
            }
            "page" => {
                if let Some(chat) = sid.as_deref().and_then(|sid| self.chats.get_mut(sid)) {
                    chat.page = None;
                }
            }
            // `not_ready` is the one `sub` error that leaves the sid held: its window follows.
            "sub" if code != "not_ready" => {
                if let Some(sid) = sid.as_deref() {
                    self.forget_chat(sid);
                }
            }
            _ => {}
        }
        self.push_change(
            Change::Chat(ChatChange::Error { sid: sid.clone(), method, id: error.id, code }),
            sid,
            frame_bytes,
            true,
        );
    }

    fn accept_blob(&mut self, frame: &Frame, frame_bytes: u64) {
        let Ok((head, bytes)) = wire::decode_blob(frame) else {
            self.protocol_error("malformed blob");
            return;
        };
        let Some(blob) = self
            .blobs
            .iter()
            .position(|blob| blob.request.id == head.id)
            .and_then(|at| self.blobs.remove(at))
        else {
            self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
            self.charge_frame_now(None, frame_bytes);
            return;
        };
        let at_end = head.start.saturating_add(bytes.len() as u64) >= head.total;
        // A row's body is its stored JSON, so a range can end inside an escape; a prompt's
        // text is decoded, so only a character can be cut.
        let given = if at_end {
            bytes.len()
        } else if blob.request.row_id.is_some() {
            whole_body_prefix(bytes)
        } else {
            whole_chars(bytes)
        };
        let next_start = head.start.saturating_add(given as u64);
        let bytes = bytes.get(..given).unwrap_or_default().to_vec();
        let sid = blob.sid;
        self.push_change(
            Change::Chat(ChatChange::Blob { sid: sid.clone(), head, next_start, bytes }),
            Some(sid),
            frame_bytes,
            true,
        );
    }

    /// The bytes this handle holds: its chat subs and requests, its buffers and the changes not
    /// yet taken. A row is never among them once its change is taken.
    pub fn held_bytes(&self) -> usize {
        fn sub_bytes(sub: &Sub) -> usize {
            sub.sid.capacity() + sub.stream.0.capacity()
        }
        let chats: usize = self
            .chats
            .iter()
            .map(|(sid, chat)| {
                sid.capacity()
                    + size_of::<ChatSub>()
                    + sub_bytes(&chat.initial)
                    + sub_bytes(&chat.request)
                    + chat.page.as_ref().map_or(0, |page| page.sid.capacity())
            })
            .sum();
        let blobs: usize = self
            .blobs
            .iter()
            .map(|blob| {
                size_of::<PendingBlob>()
                    + blob.sid.capacity()
                    + blob.request.id.capacity()
                    + blob.request.stream.0.capacity()
            })
            .sum();
        let send: usize = self.send.iter().map(Vec::capacity).sum();
        chats
            + blobs
            + send
            + self.frame_buf.capacity()
            + self.line.capacity()
            + self.changes.capacity() * size_of::<crate::QueuedChange<T>>()
    }
}

#[cfg(test)]
mod tests;
