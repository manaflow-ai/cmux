//! Post and poll one mailbox item (PROTOCOL.md "Reply mailbox", "Store and forward"), with no
//! network in it: the caller asks [`Tracker::next`] what to do, does the HTTP request, and feeds
//! the answer back. Times are Unix milliseconds the caller reads from its clock.
//!
//! - `POST` answers `{queued, delivered, seq?, expiresAt?}`; no `seq` means an older hub, which
//!   holds the item 10 minutes whatever `hold` said. `409` (the id is held with another blob) is
//!   queued; `429` is full; `403`, `400` and `413` are refused for good; anything else (5xx,
//!   a lost connection) is retried with the same bytes after a pause.
//! - `GET` is asked after 1, 2, 4 and 8 s, then every 30 s, until the hub says `applied`,
//!   `rejected` or `expired`. The phone takes `applied` and `rejected` only with the Mac's
//!   signature over the outcome; anything else is [`State::NotConfirmed`].

use serde::Deserialize;

use super::item::{OLD_HUB_HOLD_SECS, SealedItem};
use super::seal;

/// The hub keeps an outcome 10 minutes past its item's expiry.
const OUTCOME_GRACE_MS: u64 = 600_000;
const POLL_SCHEDULE_MS: [u64; 4] = [1_000, 2_000, 4_000, 8_000];
const POLL_STEADY_MS: u64 = 30_000;
const RETRY_MAX_MS: u64 = 30_000;

/// Where an item stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum State {
    /// Not accepted by the hub yet.
    Posting,
    /// The hub holds it for the Mac.
    Queued,
    /// The Mac applied it (signed).
    Applied,
    /// The Mac refused it, with its reason (signed).
    Rejected { reason: String },
    /// The hub held it until its expiry and the Mac never settled it.
    Expired,
    /// The hub reports an outcome the Mac's signature does not back: "Not confirmed by <Mac>".
    NotConfirmed,
    /// The hub is full for this Mac and phone (`429`): the person decides.
    Full,
    /// The hub refused it for good (`code` is its error code or `http_<status>`).
    Failed { code: String },
}

impl State {
    pub fn is_final(&self) -> bool {
        !matches!(self, Self::Posting | Self::Queued)
    }
}

/// One HTTP request for the caller to make; paths are under the cmux service's origin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    Post { path: String, body: String },
    Poll { path: String },
}

/// What to do now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    Send(Request),
    /// Nothing until this time (or an event the caller knows, like the app coming forward).
    Wait {
        until_ms: u64,
    },
    /// Settled: read [`Tracker::state`].
    Done,
}

#[derive(Debug, Deserialize)]
struct PostAnswer {
    #[serde(default)]
    delivered: bool,
    seq: Option<u64>,
    #[serde(rename = "expiresAt")]
    expires_at: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct PollAnswer {
    state: Option<String>,
    reason: Option<String>,
    sig: Option<String>,
    seq: Option<u64>,
    #[serde(rename = "expiresAt")]
    expires_at: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct ErrorAnswer {
    error: Option<String>,
}

pub struct Tracker {
    item: SealedItem,
    /// The Mac's pinned identity key (X9.63 hex): the one that signs outcomes.
    pinned_identity: Option<String>,
    state: State,
    old_hub: bool,
    seq: Option<u64>,
    delivered: bool,
    expires_at_ms: u64,
    due_ms: u64,
    polls: usize,
    failures: u32,
    auth_refused: bool,
}

impl Tracker {
    /// `hub_known_old`: an earlier post learned this hub reports no `seq`.
    pub fn new(item: SealedItem, pinned_identity: Option<String>, hub_known_old: bool, now_ms: u64) -> Self {
        let expires_at_ms = item.expires_at.saturating_mul(1000);
        Self {
            item,
            pinned_identity,
            state: State::Posting,
            old_hub: hub_known_old,
            seq: None,
            delivered: false,
            expires_at_ms,
            due_ms: now_ms,
            polls: 0,
            failures: 0,
            auth_refused: false,
        }
    }

    pub fn state(&self) -> &State {
        &self.state
    }
    pub fn id(&self) -> &str {
        &self.item.id
    }
    pub fn seq(&self) -> Option<u64> {
        self.seq
    }
    /// The hub reported no `seq`: it holds items 10 minutes only, so a long send may lapse.
    pub fn old_hub(&self) -> bool {
        self.old_hub
    }
    /// The hub sent it to the Mac's open socket at once (the Mac has it, not yet applied).
    pub fn delivered(&self) -> bool {
        self.delivered
    }
    /// When the hub drops it unsettled, Unix milliseconds.
    pub fn expires_at_ms(&self) -> u64 {
        self.expires_at_ms
    }
    /// The hub answered `401`: refresh the access token, then ask [`Self::next`] again.
    pub fn auth_refused(&self) -> bool {
        self.auth_refused
    }

    pub fn next(&mut self, now_ms: u64) -> Step {
        if self.state.is_final() {
            return Step::Done;
        }
        let ends = match self.state {
            State::Posting => self.item.expires_at.saturating_mul(1000),
            _ => self.expires_at_ms.saturating_add(OUTCOME_GRACE_MS),
        };
        if now_ms >= ends {
            self.state = State::Expired;
            return Step::Done;
        }
        if now_ms < self.due_ms {
            return Step::Wait { until_ms: self.due_ms };
        }
        let mac = &self.item.mac;
        if matches!(self.state, State::Posting) {
            let Some(body) = self.item.post_body(now_ms / 1000, self.old_hub) else {
                self.state = State::Expired;
                return Step::Done;
            };
            return Step::Send(Request::Post { path: format!("/v1/devices/{mac}/mailbox"), body });
        }
        self.polls += 1;
        Step::Send(Request::Poll { path: format!("/v1/devices/{mac}/mailbox/{}", self.item.id) })
    }

    /// The answer to a [`Request::Post`].
    pub fn on_post(&mut self, status: u16, body: &str, now_ms: u64) {
        if !matches!(self.state, State::Posting) {
            return;
        }
        self.auth_refused = status == 401;
        match status {
            200..=299 => {
                let answer = serde_json::from_str(body).unwrap_or(PostAnswer {
                    delivered: false,
                    seq: None,
                    expires_at: None,
                });
                self.queued(Some(answer), now_ms);
            }
            // The same id with another blob: the hub holds it already (a retried post).
            409 => self.queued(None, now_ms),
            429 => self.state = State::Full,
            400 | 403 | 404 | 413 => {
                let code = serde_json::from_str::<ErrorAnswer>(body)
                    .ok()
                    .and_then(|e| e.error)
                    .unwrap_or_else(|| format!("http_{status}"));
                self.state = State::Failed { code };
            }
            _ => self.pause(now_ms),
        }
    }

    /// The request never got an answer (no network, a timeout).
    pub fn on_transport_error(&mut self, now_ms: u64) {
        self.pause(now_ms);
    }

    /// The answer to a [`Request::Poll`].
    pub fn on_poll(&mut self, status: u16, body: &str, now_ms: u64) {
        if !matches!(self.state, State::Queued) {
            return;
        }
        self.auth_refused = status == 401;
        match status {
            200 => {}
            404 => {
                // The hub forgot it: past its expiry that is expiry; before, nothing can be said.
                self.state = if now_ms >= self.expires_at_ms { State::Expired } else { State::NotConfirmed };
                return;
            }
            _ => return self.pause(now_ms),
        }
        let Ok(answer) = serde_json::from_str::<PollAnswer>(body) else { return self.pause(now_ms) };
        if answer.seq.is_some() {
            self.seq = answer.seq;
            self.old_hub = false;
        }
        if let Some(at) = answer.expires_at {
            self.expires_at_ms = at;
        }
        match answer.state.as_deref() {
            Some("queued") => {
                self.failures = 0;
                self.due_ms = now_ms + self.poll_delay();
            }
            Some("expired") => self.state = State::Expired,
            Some(kind @ ("applied" | "rejected")) => {
                self.state =
                    match self.verified(kind == "applied", answer.reason.as_deref(), answer.sig.as_deref()) {
                        Some(None) => State::Applied,
                        Some(Some(reason)) => State::Rejected { reason },
                        None => State::NotConfirmed,
                    };
            }
            _ => self.pause(now_ms),
        }
    }

    /// Posts again after `Full` or a refused token, keeping the same bytes (the id and blob).
    pub fn retry(&mut self, now_ms: u64) {
        let retryable = match &self.state {
            State::Full => true,
            State::Failed { code } => code == "unauthorized",
            _ => false,
        };
        if retryable {
            self.state = State::Posting;
            self.due_ms = now_ms;
            self.failures = 0;
        }
    }

    /// `answer`: a 2xx post's body; `None` for a `409` (the hub holds the id already, and says
    /// nothing about itself).
    fn queued(&mut self, answer: Option<PostAnswer>, now_ms: u64) {
        self.state = State::Queued;
        self.failures = 0;
        let local_ms = self.item.expires_at.saturating_mul(1000);
        if let Some(answer) = answer {
            self.delivered = answer.delivered;
            self.seq = answer.seq;
            if answer.seq.is_some() {
                self.old_hub = false;
                self.expires_at_ms = answer.expires_at.unwrap_or(local_ms);
            } else {
                // An older hub holds every item 10 minutes, whatever `hold` said.
                self.old_hub = true;
                self.expires_at_ms = local_ms.min(now_ms + OLD_HUB_HOLD_SECS * 1000);
            }
        }
        self.due_ms = now_ms + self.poll_delay();
    }

    fn poll_delay(&self) -> u64 {
        POLL_SCHEDULE_MS.get(self.polls).copied().unwrap_or(POLL_STEADY_MS)
    }

    fn pause(&mut self, now_ms: u64) {
        self.failures = self.failures.saturating_add(1);
        let backoff = 1_000u64.saturating_mul(1 << self.failures.min(5)).min(RETRY_MAX_MS);
        self.due_ms = now_ms + backoff;
    }

    /// `Some(None)` an applied outcome, `Some(Some(reason))` a rejected one, both with the Mac's
    /// signature checked; `None` when it does not check.
    fn verified(&self, applied: bool, reason: Option<&str>, sig: Option<&str>) -> Option<Option<String>> {
        let (sig, pinned) = (sig?, self.pinned_identity.as_deref()?);
        let reason = if applied { None } else { reason };
        let message = seal::ack_message(&self.item.mac, &self.item.id, applied, reason);
        if !seal::verify(pinned, &message, sig) {
            return None;
        }
        Some(if applied {
            None
        } else {
            Some(reason.filter(|r| !r.is_empty()).unwrap_or("refused").to_string())
        })
    }
}
