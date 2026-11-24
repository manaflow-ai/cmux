//! The terminal composer's Send (`cmux-composer-send`): the draft and its Return as one keyed
//! `send`, kept across a reconnect, applied once on the Mac. The Swift session asks for the
//! next request, sends it with the terminal's surface, and reports the answer; the outbox
//! decides what goes, under which key, and what the person is told when it gives up.
//!
//! One object per terminal session, called from its actor; a mutex keeps it `Sync` for uniffi
//! and is held only for the call. Time is the session's own monotonic clock in milliseconds
//! (`now_ms`, from any origin, never going back), so a test's clock drives the hold too.

use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use cmux_composer_send::{Answer, Done, Form, Outbox, Outcome};

/// What came of one attempt, as the session saw it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ComposerSendAnswer {
    /// The daemon answered success (applied now, or earlier under the same key).
    Applied,
    /// The daemon refused it and nothing was written.
    Refused,
    /// No answer: the channel failed or timed out after the request may have been written.
    Lost,
    /// An error that does not say nothing was written (no `known-not-delivered`): may be typed.
    Uncertain,
}

/// How a Send ended.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ComposerSendOutcome {
    /// The Mac has it, typed once.
    Sent,
    /// The Mac never got it: the text goes back to the composer.
    NotSent { text: String },
    /// It may have reached the Mac and the hold ran out: say so, and keep the text out of the
    /// composer, or the person sends it twice.
    MaybeSent { text: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ComposerSendDone {
    pub seq: u64,
    pub outcome: ComposerSendOutcome,
}

/// One `send` to make: `params` is the JSON object without `surface`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ComposerSendRequest {
    pub seq: u64,
    pub params_json: String,
}

struct Inner {
    outbox: Outbox,
    form: Option<Form>,
    /// `now_ms` 0 on the outbox's clock.
    origin: Instant,
}

#[derive(uniffi::Object)]
pub struct ComposerOutbox {
    inner: Mutex<Inner>,
}

impl ComposerOutbox {
    fn inner(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Inner {
    fn at(&self, now_ms: u64) -> Instant {
        self.origin + Duration::from_millis(now_ms)
    }
}

fn done(done: Done) -> ComposerSendDone {
    let outcome = match done.outcome {
        Outcome::Sent => ComposerSendOutcome::Sent,
        Outcome::NotSent { text } => ComposerSendOutcome::NotSent { text },
        Outcome::MaybeSent { text } => ComposerSendOutcome::MaybeSent { text },
    };
    ComposerSendDone { seq: done.seq, outcome }
}

#[uniffi::export]
impl ComposerOutbox {
    /// `nonce`: unique to this session across the daemon's key memory. `hold_ms`: how long a
    /// Send waits for the terminal before it is given up (capped below the daemon's key memory).
    #[uniffi::constructor]
    pub fn new(nonce: String, hold_ms: u64) -> Self {
        Self {
            inner: Mutex::new(Inner {
                outbox: Outbox::new(nonce, Duration::from_millis(hold_ms)),
                form: None,
                origin: Instant::now(),
            }),
        }
    }

    /// The attached daemon's `identify` capabilities. Returns whether it takes keyed Sends; until
    /// a daemon that does is attached, Sends wait in the outbox.
    pub fn set_capabilities(&self, capabilities: Vec<String>) -> bool {
        let mut inner = self.inner();
        inner.form = Form::from_caps(capabilities.iter().map(String::as_str));
        inner.form.is_some()
    }

    /// Whether the attached daemon takes keyed Sends (false before the first attach).
    pub fn is_served(&self) -> bool {
        self.inner().form.is_some()
    }

    /// A tap on Send at `now_ms`. Returns the Send's number.
    pub fn push(&self, text: String, submit: bool, now_ms: u64) -> u64 {
        let mut inner = self.inner();
        let at = inner.at(now_ms);
        inner.outbox.push(text, submit, at)
    }

    /// A tap on Send of a one-line draft for a full-screen program at `now_ms`: typed, then
    /// Return, in one request (`send-typed-submit-v1`). Returns the Send's number.
    pub fn push_typed(&self, text: String, now_ms: u64) -> u64 {
        let mut inner = self.inner();
        let at = inner.at(now_ms);
        inner.outbox.push_typed(text, at)
    }

    /// The next request to send, in tap order behind those in flight (up to
    /// `cmux_composer_send::MAX_IN_FLIGHT`), when a keyed daemon is attached.
    pub fn next_request(&self) -> Option<ComposerSendRequest> {
        let mut inner = self.inner();
        let form = inner.form?;
        let (seq, params) = inner.outbox.next_request(form)?;
        Some(ComposerSendRequest { seq, params_json: params.to_string() })
    }

    /// The answer to the request for `seq`. A lost one goes again under its key.
    pub fn answer(&self, seq: u64, answer: ComposerSendAnswer) -> Option<ComposerSendDone> {
        let answer = match answer {
            ComposerSendAnswer::Applied => Answer::Applied,
            ComposerSendAnswer::Refused => Answer::Refused,
            ComposerSendAnswer::Lost => Answer::Lost,
            ComposerSendAnswer::Uncertain => Answer::Uncertain,
        };
        self.inner().outbox.answer(seq, answer).map(done)
    }

    /// The channel dropped: what was in flight goes again on the next one.
    pub fn link_lost(&self) {
        self.inner().outbox.link_lost();
    }

    /// One Send, given up now (the session dropped it), unless it is in flight.
    pub fn give_up_send(&self, seq: u64) -> Option<ComposerSendDone> {
        self.inner().outbox.give_up_send(seq).map(done)
    }

    /// Every Send, given up now (the attached daemon takes no keys), in tap order.
    pub fn give_up(&self) -> Vec<ComposerSendDone> {
        self.inner().outbox.give_up().into_iter().map(done).collect()
    }

    /// Sends past the hold at `now_ms`, given up, in tap order.
    pub fn expire(&self, now_ms: u64) -> Vec<ComposerSendDone> {
        let mut inner = self.inner();
        let at = inner.at(now_ms);
        inner.outbox.expire(at).into_iter().map(done).collect()
    }

    /// Milliseconds after `now_ms` until the oldest Send runs out of hold (0 when it has), or
    /// none when empty.
    pub fn next_deadline_ms(&self, now_ms: u64) -> Option<u64> {
        let inner = self.inner();
        let deadline = inner.outbox.next_deadline()?;
        let left = deadline.saturating_duration_since(inner.at(now_ms));
        Some(u64::try_from(left.as_millis()).unwrap_or(u64::MAX))
    }

    /// Sends not answered yet.
    pub fn pending(&self) -> u32 {
        u32::try_from(self.inner().outbox.len()).unwrap_or(u32::MAX)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn caps(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn a_send_before_the_first_attach_waits_then_goes_as_one_keyed_request() {
        let outbox = ComposerOutbox::new("phone-1".into(), 30_000);
        let seq = outbox.push("ls -la".into(), true, 1_000);
        assert_eq!(outbox.next_request(), None, "no daemon attached yet: it waits");
        assert!(outbox.set_capabilities(caps(&["send-key-v1", "send-expect-agent-v1"])));
        let request = outbox.next_request().expect("a request once attached");
        assert_eq!(request.seq, seq);
        let params: serde_json::Value = serde_json::from_str(&request.params_json).unwrap();
        assert_eq!(params["text"], "ls -la");
        assert_eq!(params["paste"], true);
        assert_eq!(params["submit"], true);
        assert_eq!(params["key"], "phone-1-1");
    }

    #[test]
    fn a_lost_answer_goes_again_under_the_same_key_on_the_next_channel() {
        let outbox = ComposerOutbox::new("phone-1".into(), 30_000);
        outbox.set_capabilities(caps(&["send-key-v1"]));
        let seq = outbox.push("echo hi".into(), true, 1_000);
        let first = outbox.next_request().unwrap();
        outbox.link_lost();
        let again = outbox.next_request().unwrap();
        assert_eq!(first, again, "same request, same key");
        let params: serde_json::Value = serde_json::from_str(&again.params_json).unwrap();
        assert_eq!(params["text"], "echo hi\r", "text and Return in one write");
        assert_eq!(
            outbox.answer(seq, ComposerSendAnswer::Applied),
            Some(ComposerSendDone { seq, outcome: ComposerSendOutcome::Sent })
        );
        assert_eq!(outbox.pending(), 0);
    }

    #[test]
    fn the_sessions_clock_drives_the_hold() {
        let outbox = ComposerOutbox::new("phone-1".into(), 30_000);
        let seq = outbox.push("make".into(), true, 1_000_000);
        assert_eq!(outbox.next_deadline_ms(1_010_000), Some(20_000));
        assert!(outbox.expire(1_029_999).is_empty());
        assert_eq!(
            outbox.expire(1_030_000),
            vec![ComposerSendDone { seq, outcome: ComposerSendOutcome::NotSent { text: "make".into() } }]
        );
    }

    #[test]
    fn a_daemon_without_keys_is_not_served() {
        let outbox = ComposerOutbox::new("phone-1".into(), 30_000);
        assert!(!outbox.set_capabilities(caps(&["send-expect-agent-v1"])));
        outbox.push("x".into(), true, 1_000);
        assert_eq!(outbox.next_request(), None);
    }
}
