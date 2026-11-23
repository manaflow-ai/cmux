//! Bounded, atomic chat draft updates.
//!
//! A draft is replaced by one sibling rename.  The writer deliberately does not call
//! `sync_all`: the actor's group checkpoint owns the durability sync for a batch of updates.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// Maximum UTF-8 bytes in one chat draft.
pub const MAX_DRAFT_BYTES: usize = 256 * 1024;
/// Stable refusal reason for payloads over a bounded state limit.
pub const TOO_LARGE: &str = "too_large";

/// Errors shared by draft and presence admission.
#[derive(Debug)]
pub enum ActError {
    /// The draft exceeds [`MAX_DRAFT_BYTES`].
    DraftTooLarge { bytes: usize, max: usize },
    /// A presence set exceeds the encoded bound.  Presence currently trims before this can be
    /// returned; keeping the variant preserves the typed refusal for callers that validate an
    /// already encoded operation.
    PresenceTooLarge { bytes: usize, max: usize },
    /// A presence set contains more than [`crate::chat::presence::MAX_PRESENCE_PEOPLE`] non-owner
    /// ids.
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
    /// Stable protocol reason for size refusals.
    pub const fn reason(&self) -> Option<&'static str> {
        match self {
            Self::DraftTooLarge { .. } | Self::PresenceTooLarge { .. } => Some(TOO_LARGE),
            _ => None,
        }
    }
}

/// Checks a draft before opening a temporary file.
pub fn validate_draft(text: &str) -> Result<(), ActError> {
    let bytes = text.len();
    if bytes > MAX_DRAFT_BYTES {
        return Err(ActError::DraftTooLarge { bytes, max: MAX_DRAFT_BYTES });
    }
    Ok(())
}

/// The result of a successful atomic draft replacement.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DraftCommit {
    pub path: PathBuf,
    pub bytes: usize,
}

/// Replaces one chat's draft file atomically.
///
/// The temporary file has a fixed sibling name so a group sync can cover all updates.  The
/// caller serializes writes for a chat; a failed write removes the fixed temporary file.
pub fn write_draft_atomic(path: impl AsRef<Path>, text: &str) -> Result<DraftCommit, ActError> {
    validate_draft(text)?;
    let path = path.as_ref();
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path.file_name().ok_or_else(|| {
        ActError::Io(io::Error::new(io::ErrorKind::InvalidInput, "draft path has no file name"))
    })?;
    let temp = parent.join(format!(".{}.tmp", name.to_string_lossy()));

    let result = (|| {
        let mut file = OpenOptions::new().write(true).create(true).truncate(true).open(&temp)?;
        file.write_all(text.as_bytes())?;
        drop(file);
        fs::rename(&temp, path)?;
        Ok(DraftCommit { path: path.to_owned(), bytes: text.len() })
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result.map_err(ActError::Io)
}
