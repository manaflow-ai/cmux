//! Bounded presence replacement state and typing admission.

use super::draft::ActError;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, VecDeque};
use std::time::{Duration, Instant};

/// Maximum encoded bytes in one presence replacement operation.
pub const MAX_PRESENCE_BYTES: usize = 4 * 1024;
/// Maximum distinct people other than the owner in a presence set.
pub const MAX_PRESENCE_PEOPLE: usize = 32;
/// An `on` typing state expires unless renewed.
pub const TYPING_EXPIRY: Duration = Duration::from_secs(8);
/// Typing changes admitted from one connection in a rolling second.
pub const TYPING_RATE_LIMIT: usize = 2;
const TYPING_WINDOW: Duration = Duration::from_secs(1);

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

/// A complete replacement for one chat's presence state. It has no sequence or replay marker.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PresenceStateOp {
    /// Kept for actor-side routing; the wire ChatOp intentionally omits it because the stream
    /// already names the chat.
    pub chat_id: String,
    pub participants: Vec<PresencePerson>,
    /// Number of participants removed to fit the encoded bound.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub trimmed: usize,
}

fn is_zero(value: &usize) -> bool {
    *value == 0
}

impl PresenceStateOp {
    /// Builds a replacement set for `local_id`, sorting by id for deterministic bytes. Oversize
    /// sets are trimmed from the largest non-local ids first and report the count in `trimmed`.
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
        let mut op = Self { chat_id: chat_id.into(), participants, trimmed: 0 };
        while op.encoded_len() > MAX_PRESENCE_BYTES {
            let index = op
                .participants
                .iter()
                .rposition(|person| person.id != local_id)
                .or_else(|| op.participants.len().checked_sub(1));
            let Some(index) = index else { break };
            op.participants.remove(index);
            op.trimmed += 1;
        }
        Ok(op)
    }

    /// Convenience constructor for the v1 owner identity.
    pub fn replace_owner(
        chat_id: impl Into<String>,
        participants: Vec<PresencePerson>,
    ) -> Result<Self, ActError> {
        Self::replace(chat_id, "owner", participants)
    }

    pub fn validate_size(&self) -> Result<(), ActError> {
        let bytes = serde_json::to_vec(self)
            .map_err(|error| ActError::Io(std::io::Error::other(error)))?
            .len();
        if bytes > MAX_PRESENCE_BYTES {
            return Err(ActError::PresenceTooLarge { bytes, max: MAX_PRESENCE_BYTES });
        }
        Ok(())
    }

    pub fn encoded_len(&self) -> usize {
        serde_json::to_vec(self).map_or(usize::MAX, |bytes| bytes.len())
    }
}

/// Why a typing update was refused.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TypingRateLimited {
    pub retry_after: Duration,
}

/// Connection-scoped typing admission and expiry.
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

    /// Drops all typing state for a closed connection, including its rate-limit deque.
    pub fn disconnect(&mut self, connection: &str) {
        self.calls.remove(connection);
        self.active.retain(|(conn, _), _| conn != connection);
    }

    pub fn is_typing(&mut self, connection: &str, person: &str, now: Instant) -> bool {
        self.expire(now);
        self.active.contains_key(&(connection.to_owned(), person.to_owned()))
    }

    pub fn expire(&mut self, now: Instant) {
        self.active.retain(|_, deadline| *deadline > now);
        self.calls.retain(|_, calls| {
            while calls.front().is_some_and(|at| now.duration_since(*at) >= TYPING_WINDOW) {
                calls.pop_front();
            }
            !calls.is_empty()
        });
    }
}
