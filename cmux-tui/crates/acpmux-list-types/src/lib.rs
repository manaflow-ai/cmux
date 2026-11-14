//! Shared list records and their bounds, independent of index storage.

use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

pub mod folders;
pub mod text;

/// The identity of a row is independent of its current sort position.
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RowKey {
    pub origin: Arc<str>,
    pub chat_id: Arc<str>,
}

impl RowKey {
    pub fn new(origin: impl Into<Arc<str>>, chat_id: impl Into<Arc<str>>) -> Self {
        Self { origin: origin.into(), chat_id: chat_id.into() }
    }

    pub fn validate(&self) -> io::Result<()> {
        if self.origin.len() > MAX_FIELD_BYTES || self.chat_id.len() > MAX_FIELD_BYTES {
            REJECTED_KEYS.fetch_add(1, AtomicOrdering::Relaxed);
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "row key exceeds 256 bytes"));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct ForkOf {
    #[serde(flatten)]
    pub key: RowKey,
    pub seq: u64,
}

/// The on-wire summary of one chat. `extra` is opaque to the daemon.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub chat_id: String,
    pub title: String,
    pub harness: String,
    pub state: String,
    /// Milliseconds since the Unix epoch, matching v1 `updatedAt` and `updatedMs`.
    pub last_activity: u64,
    pub unread: u32,
    pub workspace: Option<String>,
    pub origin: String,
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub archived: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_form: Option<Box<RawValue>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<RowKey>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_of: Option<ForkOf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    #[serde(default = "empty_object")]
    pub extra: Box<RawValue>,
}

/// Name used by the design document for a summary's durable record.
pub type SummaryRecord = Summary;

/// A summary is deliberately small: the list can never be made unbounded by
/// one harness supplied title or opaque extension.
pub const MAX_TITLE_BYTES: usize = 256;
/// Activity keeps a closed, unpinned chat hot for thirty days.
pub const HOT_WINDOW_MS: u64 = 30 * 24 * 60 * 60 * 1_000;
pub const MAX_SUMMARY_BYTES: usize = 2 * 1024;

/// Returns whether a v1 list state belongs to the live view.
pub fn is_live_state(state: &str) -> bool {
    state != "closed"
}
static REJECTED_KEYS: AtomicUsize = AtomicUsize::new(0);
static OMITTED_FOLDERS: AtomicUsize = AtomicUsize::new(0);
static CUT_FIELDS: AtomicUsize = AtomicUsize::new(0);
static EMPTY_EXTRAS: AtomicUsize = AtomicUsize::new(0);

pub fn rejected_keys() -> usize {
    REJECTED_KEYS.load(AtomicOrdering::Relaxed)
}
pub fn omitted_folders() -> usize {
    OMITTED_FOLDERS.load(AtomicOrdering::Relaxed)
}
pub fn cut_fields() -> usize {
    CUT_FIELDS.load(AtomicOrdering::Relaxed)
}
pub fn empty_extras() -> usize {
    EMPTY_EXTRAS.load(AtomicOrdering::Relaxed)
}
pub const MAX_FIELD_BYTES: usize = 256;

fn empty_object() -> Box<RawValue> {
    RawValue::from_string("{}".to_owned()).unwrap_or_else(|_| RawValue::NULL.to_owned())
}

impl Clone for Summary {
    fn clone(&self) -> Self {
        Self {
            chat_id: self.chat_id.clone(),
            title: self.title.clone(),
            harness: self.harness.clone(),
            state: self.state.clone(),
            last_activity: self.last_activity,
            unread: self.unread,
            workspace: self.workspace.clone(),
            origin: self.origin.clone(),
            pinned: self.pinned,
            archived: self.archived,
            peer_form: self.peer_form.as_ref().map(|value| value.to_owned()),
            parent: self.parent.clone(),
            fork_of: self.fork_of.clone(),
            folder: self.folder.clone(),
            extra: self.extra.to_owned(),
        }
    }
}

impl Summary {
    /// A compact default useful when a chat has not supplied a title yet.
    pub fn new(chat_id: impl Into<String>) -> Self {
        Self {
            chat_id: chat_id.into(),
            title: String::new(),
            harness: String::new(),
            state: String::new(),
            last_activity: 0,
            unread: 0,
            workspace: None,
            origin: "local".to_owned(),
            pinned: false,
            archived: false,
            peer_form: None,
            parent: None,
            fork_of: None,
            folder: None,
            extra: empty_object(),
        }
    }

    pub fn key(&self) -> RowKey {
        RowKey::new(self.origin.as_str(), self.chat_id.as_str())
    }

    /// Whether v1's one-level list folding can place `child` beneath `parent`.
    /// The decision is made from the two rows supplied by the same snapshot, so an
    /// archived or non-root parent cannot hide a child after it changes.
    pub fn listed_under(child: &Summary, parent: Option<&Summary>) -> bool {
        let Some(parent) = parent else { return false };
        if child.key() == parent.key() || parent.parent.is_some() || parent.archived {
            return false;
        }
        child.parent.as_ref() == Some(&parent.key())
    }

    /// Keys are refused, never shortened. Opaque data stays opaque.
    pub fn validate(&self) -> io::Result<()> {
        self.key().validate()?;
        if let Some(parent) = &self.parent {
            parent.validate()?;
        }
        if let Some(fork) = &self.fork_of {
            fork.key.validate()?;
        }
        if self.folder.as_ref().is_some_and(|folder| folder.len() > 1024) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "folder exceeds 1024 bytes"));
        }
        if text::text_len(self) > MAX_SUMMARY_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "summary texts exceed budget"));
        }
        Ok(())
    }

    pub fn prepare(mut self) -> io::Result<Self> {
        if self.folder.as_ref().is_some_and(|folder| folder.len() > 1024) {
            self.folder = None;
            OMITTED_FOLDERS.fetch_add(1, AtomicOrdering::Relaxed);
        }
        let summary = self.bounded();
        summary.validate()?;
        Ok(summary)
    }

    pub fn is_live(&self) -> bool {
        is_live_state(&self.state)
    }

    pub fn is_hot_at(&self, now: u64) -> bool {
        self.pinned || self.is_live() || self.last_activity >= now.saturating_sub(HOT_WINDOW_MS)
    }

    /// Opaque extension bytes are compared without parsing or re-encoding.
    pub fn same_content(&self, other: &Self) -> bool {
        let Self {
            chat_id,
            title,
            harness,
            state,
            last_activity,
            unread,
            workspace,
            origin,
            pinned,
            archived,
            peer_form,
            parent,
            fork_of,
            folder,
            extra,
        } = self;
        chat_id == &other.chat_id
            && title == &other.title
            && harness == &other.harness
            && state == &other.state
            && last_activity == &other.last_activity
            && unread == &other.unread
            && workspace == &other.workspace
            && origin == &other.origin
            && pinned == &other.pinned
            && archived == &other.archived
            && peer_form.as_ref().map(|value| value.get())
                == other.peer_form.as_ref().map(|value| value.get())
            && parent == &other.parent
            && fork_of == &other.fork_of
            && folder == &other.folder
            && extra.get() == other.extra.get()
    }

    pub fn encoded_len(&self) -> usize {
        serde_json::to_vec(self).map_or(0, |bytes| bytes.len())
    }

    /// Clamps user supplied text at the index boundary. `extra` stays opaque;
    /// an extension that cannot fit is represented by the empty object rather
    /// than parsed or allowed to expand the list frame.
    pub fn bounded(mut self) -> Self {
        self.title = truncate_utf8(&self.title, MAX_TITLE_BYTES);
        self.harness = truncate_utf8(&self.harness, MAX_FIELD_BYTES);
        self.state = truncate_utf8(&self.state, MAX_FIELD_BYTES);
        self.workspace = self.workspace.map(|value| truncate_utf8(&value, MAX_FIELD_BYTES));
        if text::text_len(&self) > MAX_SUMMARY_BYTES {
            self.extra = empty_object();
            EMPTY_EXTRAS.fetch_add(1, AtomicOrdering::Relaxed);
        }
        if text::text_len(&self) > MAX_SUMMARY_BYTES {
            self.title = truncate_utf8(&self.title, MAX_TITLE_BYTES / 2);
        }
        // JSON escaping can make a 256-byte UTF-8 field larger than its text
        // length. Keep shrinking textual fields until the serialized record,
        // including opaque bytes, is inside the wire bound.
        while text::text_len(&self) > MAX_SUMMARY_BYTES {
            let mut changed = false;
            macro_rules! shrink {
                ($value:expr) => {
                    if $value.len() > 1 {
                        let next = $value.len() / 2;
                        $value = truncate_utf8(&$value, next);
                        changed = true;
                    }
                };
            }
            shrink!(self.title);
            if text::text_len(&self) > MAX_SUMMARY_BYTES {
                shrink!(self.harness);
            }
            if text::text_len(&self) > MAX_SUMMARY_BYTES {
                shrink!(self.state);
            }
            if text::text_len(&self) > MAX_SUMMARY_BYTES
                && let Some(value) = self.workspace.as_mut()
            {
                shrink!(*value);
            }
            if !changed {
                break;
            }
        }
        self
    }
}

fn truncate_utf8(value: &str, max: usize) -> String {
    if value.len() <= max {
        return value.to_owned();
    }
    CUT_FIELDS.fetch_add(1, AtomicOrdering::Relaxed);
    let mut end = max;
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    value.get(..end).unwrap_or_default().to_owned()
}

/// The durable state of one remote origin. `local` is implicit and never has
/// an origin record in the index log.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum OriginState {
    Connected,
    Down,
    Stale,
    Removed,
}

/// A folder is scoped by origin.  Two machines may use the same folder name
/// without sharing a view.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderKey {
    pub origin: Arc<str>,
    pub folder: Arc<str>,
}

impl FolderKey {
    pub fn new(origin: impl Into<Arc<str>>, folder: impl Into<Arc<str>>) -> Self {
        Self { origin: origin.into(), folder: folder.into() }
    }

    pub fn of(summary: &Summary) -> Option<Self> {
        summary.folder.as_ref().map(|folder| Self::new(summary.origin.as_str(), folder.as_str()))
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct ListFilter {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    /// Select descendants rooted at this row key; `cold` chooses the snapshot part.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<RowKey>,
    /// Select one origin/folder; `cold` chooses the snapshot part.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<FolderKey>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub forks: Option<RowKey>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cold: bool,
}

impl ListFilter {
    pub fn family(root: RowKey) -> Self {
        Self { family: Some(root), ..Self::default() }
    }

    pub fn folder(folder: FolderKey) -> Self {
        Self { folder: Some(folder), ..Self::default() }
    }

    pub fn forks(root: RowKey) -> Self {
        Self { forks: Some(root), ..Self::default() }
    }

    pub fn matches(&self, summary: &Summary) -> bool {
        self.workspace.as_ref().is_none_or(|value| summary.workspace.as_ref() == Some(value))
            && self.origin.as_ref().is_none_or(|value| &summary.origin == value)
            && self.state.as_ref().is_none_or(|value| &summary.state == value)
            && self
                .folder
                .as_ref()
                .is_none_or(|value| FolderKey::of(summary).as_ref() == Some(value))
            && self
                .forks
                .as_ref()
                .is_none_or(|value| summary.fork_of.as_ref().is_some_and(|fork| &fork.key == value))
    }
}
