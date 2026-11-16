//! Bounded, transport-neutral state used by the v2 `act` path.
//!
//! These helpers deliberately do not know about a journal, sequence numbers, replay, or a
//! frontend. Drafts are replaced by one rename, while presence is a latest-value state stream:
//! submitting a newer set replaces the pending set for that chat.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Maximum UTF-8 bytes in one chat draft.
pub const MAX_DRAFT_BYTES: usize = 256 * 1024;
/// Maximum encoded bytes in one presence replacement operation.
pub const MAX_PRESENCE_BYTES: usize = 4 * 1024;
/// Maximum distinct people other than the owner in a presence set.
pub const MAX_PRESENCE_PEOPLE: usize = 32;
/// Stable refusal reason for payloads over either bounded state limit.
pub const TOO_LARGE: &str = "too_large";
/// An `on` typing state expires unless renewed.
pub const TYPING_EXPIRY: Duration = Duration::from_secs(8);
/// Typing changes admitted from one connection in a rolling second.
pub const TYPING_RATE_LIMIT: usize = 2;
const TYPING_WINDOW: Duration = Duration::from_secs(1);

static TEMP_ID: AtomicU64 = AtomicU64::new(0);

/// A refusal from the draft writer or presence validator.
#[derive(Debug)]
pub enum ActError {
    /// The draft exceeds [`MAX_DRAFT_BYTES`].
    DraftTooLarge { bytes: usize, max: usize },
    /// A presence set exceeds [`MAX_PRESENCE_BYTES`] after JSON encoding.
    PresenceTooLarge { bytes: usize, max: usize },
    /// A presence set contains more than [`MAX_PRESENCE_PEOPLE`] non-owner ids.
    PresenceTooManyPeople { people: usize, max: usize },
    /// A presence set contains an id more than once.
    PresenceDuplicatePerson(String),
    /// The presence set contains an empty person id.
    PresenceEmptyPersonId,
    /// The operation could not be written and renamed.
    Io(io::Error),
}

impl std::fmt::Display for ActError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DraftTooLarge { bytes, max } => {
                write!(f, "draft is {bytes} bytes; maximum is {max}")
            }
            Self::PresenceTooLarge { bytes, max } => {
                write!(f, "presence is {bytes} bytes; maximum is {max}")
            }
            Self::PresenceTooManyPeople { people, max } => {
                write!(f, "presence has {people} people; maximum is {max}")
            }
            Self::PresenceDuplicatePerson(id) => write!(f, "presence repeats person {id:?}"),
            Self::PresenceEmptyPersonId => f.write_str("presence person id is empty"),
            Self::Io(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for ActError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for ActError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl ActError {
    /// Stable protocol reason for size refusals. Other validation errors are intentionally
    /// represented by their typed variant until a transport chooses its own error vocabulary.
    pub const fn reason(&self) -> Option<&'static str> {
        match self {
            Self::DraftTooLarge { .. } | Self::PresenceTooLarge { .. } => Some(TOO_LARGE),
            _ => None,
        }
    }
}

/// Checks a draft before opening a temporary file. A too-large draft therefore cannot alter the
/// existing canonical file.
pub fn validate_draft(text: &str) -> Result<(), ActError> {
    let bytes = text.len();
    if bytes > MAX_DRAFT_BYTES {
        return Err(ActError::DraftTooLarge { bytes, max: MAX_DRAFT_BYTES });
    }
    Ok(())
}

/// The result of a successful atomic draft replacement. Returning only after this value exists
/// means callers can acknowledge the write after the canonical rename, then schedule their next
/// group sync independently.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DraftCommit {
    pub path: PathBuf,
    pub bytes: usize,
}

/// Replaces one chat's draft file atomically.
///
/// The temporary file is created beside `path`, written and synced, and then renamed over the
/// canonical file. A failed size check happens before any filesystem operation. The parent
/// directory is intentionally not synced here: callers may fold that sync into their next group.
pub fn write_draft_atomic(path: impl AsRef<Path>, text: &str) -> Result<DraftCommit, ActError> {
    validate_draft(text)?;
    let path = path.as_ref();
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path.file_name().ok_or_else(|| {
        ActError::Io(io::Error::new(io::ErrorKind::InvalidInput, "draft path has no file name"))
    })?;
    let id = TEMP_ID.fetch_add(1, Ordering::Relaxed);
    let temp =
        parent.join(format!(".{}.tmp-{}-{}", name.to_string_lossy(), std::process::id(), id));

    let result = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).open(&temp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, path)?;
        Ok(DraftCommit { path: path.to_owned(), bytes: text.len() })
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result.map_err(ActError::Io)
}

/// One person in a presence replacement set.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PresencePerson {
    pub id: String,
    pub name: String,
    pub devices: u32,
    pub viewing: bool,
    pub typing: bool,
}

/// A complete replacement for one chat's presence state. It has no sequence or replay marker:
/// the latest valid set is authoritative.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PresenceStateOp {
    pub chat_id: String,
    pub participants: Vec<PresencePerson>,
}

impl PresenceStateOp {
    /// Builds and validates a replacement set for `local_id`, sorting by id for deterministic
    /// bytes. The local person is excluded from [`MAX_PRESENCE_PEOPLE`]; callers should pass the
    /// identity used by their connection, including when it is not the conventional `owner` id.
    pub fn replace(
        chat_id: impl Into<String>,
        local_id: &str,
        mut participants: Vec<PresencePerson>,
    ) -> Result<Self, ActError> {
        participants.sort_by(|a, b| a.id.cmp(&b.id));
        let mut seen = BTreeMap::new();
        for person in &participants {
            if person.id.is_empty() {
                return Err(ActError::PresenceEmptyPersonId);
            }
            if seen.insert(person.id.clone(), ()).is_some() {
                return Err(ActError::PresenceDuplicatePerson(person.id.clone()));
            }
        }
        let people = participants.iter().filter(|person| person.id != local_id).count();
        if people > MAX_PRESENCE_PEOPLE {
            return Err(ActError::PresenceTooManyPeople { people, max: MAX_PRESENCE_PEOPLE });
        }
        let op = Self { chat_id: chat_id.into(), participants };
        op.validate_size()?;
        Ok(op)
    }

    /// Convenience constructor for the v1 owner identity. New callers with a distinct local
    /// identity should use [`Self::replace`] directly.
    pub fn replace_owner(
        chat_id: impl Into<String>,
        participants: Vec<PresencePerson>,
    ) -> Result<Self, ActError> {
        Self::replace(chat_id, "owner", participants)
    }

    pub fn validate_size(&self) -> Result<(), ActError> {
        let bytes =
            serde_json::to_vec(self).map_err(|error| ActError::Io(io::Error::other(error)))?.len();
        if bytes > MAX_PRESENCE_BYTES {
            return Err(ActError::PresenceTooLarge { bytes, max: MAX_PRESENCE_BYTES });
        }
        Ok(())
    }

    pub fn encoded_len(&self) -> usize {
        serde_json::to_vec(self).map_or(usize::MAX, |bytes| bytes.len())
    }
}

/// A latest-value queue. A second replacement for one chat coalesces the first; different chats
/// retain their own pending replacement. There is intentionally no log, sequence, or replay API.
#[derive(Clone, Debug, Default)]
pub struct PresenceCoalescer {
    pending: BTreeMap<String, PresenceStateOp>,
    order: VecDeque<String>,
}

impl PresenceCoalescer {
    pub fn submit(&mut self, op: PresenceStateOp) -> Result<bool, ActError> {
        op.validate_size()?;
        let chat = op.chat_id.clone();
        let replaced = self.pending.insert(chat.clone(), op).is_some();
        if !replaced {
            self.order.push_back(chat);
        }
        Ok(replaced)
    }

    pub fn pop(&mut self) -> Option<PresenceStateOp> {
        let chat = self.order.pop_front()?;
        self.pending.remove(&chat)
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

/// Why a typing update was refused.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TypingRateLimited {
    pub retry_after: Duration,
}

/// Connection-scoped typing admission and expiry. The caller supplies `Instant` values so the
/// actor can use its own clock and tests do not need sleeps.
#[derive(Debug, Default)]
pub struct TypingTracker {
    calls: BTreeMap<String, VecDeque<Instant>>,
    active: BTreeMap<(String, String), Instant>,
}

impl TypingTracker {
    pub fn update(
        &mut self,
        connection: impl Into<String>,
        person: impl Into<String>,
        on: bool,
        now: Instant,
    ) -> Result<(), TypingRateLimited> {
        let connection = connection.into();
        let person = person.into();
        let calls = self.calls.entry(connection.clone()).or_default();
        while calls.front().is_some_and(|at| now.duration_since(*at) >= TYPING_WINDOW) {
            calls.pop_front();
        }
        if calls.len() >= TYPING_RATE_LIMIT {
            let retry_after = calls
                .front()
                .map(|at| TYPING_WINDOW.saturating_sub(now.duration_since(*at)))
                .unwrap_or_default();
            return Err(TypingRateLimited { retry_after });
        }
        calls.push_back(now);
        let key = (connection, person);
        if on {
            self.active.insert(key, now + TYPING_EXPIRY);
        } else {
            self.active.remove(&key);
        }
        Ok(())
    }

    pub fn is_typing(&mut self, connection: &str, person: &str, now: Instant) -> bool {
        self.expire(now);
        self.active.contains_key(&(connection.to_owned(), person.to_owned()))
    }

    pub fn expire(&mut self, now: Instant) {
        self.active.retain(|_, deadline| *deadline > now);
    }
}

#[cfg(test)]
#[path = "act_tests.rs"]
mod act_tests;
