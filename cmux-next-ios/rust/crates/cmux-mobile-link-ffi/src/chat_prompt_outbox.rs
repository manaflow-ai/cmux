//! The agent chat's prompts on their way to the Mac (`cmux_composer_send::chat`): keyed by
//! `promptId`, written one at a time in tap order, a resend once a written one's answer was lost,
//! retried with a jittered, capped backoff, queued while offline and given up past the hold. The
//! Swift chat source asks for the next prompt to write, writes it and reports what happened; the
//! outbox decides what goes, as what, and how each prompt looks.
//!
//! One object per chat source, called from the main actor; a mutex keeps it `Sync` for uniffi
//! and is held only for the call. Time is the source's own monotonic clock in milliseconds
//! (`now_ms`, from any origin, never going back), so a test's clock drives the hold too.

use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use cmux_composer_send::chat::{PromptDone, PromptLook, PromptOutbox, PromptOutcome};

/// How a prompt ended.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ChatPromptOutcome {
    /// The Mac answered it.
    Sent,
    /// The Mac refused it (nothing ran); the source says why in the Mac's words.
    Refused { text: String },
    /// It never left before the hold ran out: nothing ran, the text goes back.
    NotSent { text: String },
    /// It was written and its answer never came, and the hold ran out: it may have run.
    MaybeSent { text: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatPromptDone {
    pub prompt_id: String,
    pub outcome: ChatPromptOutcome,
}

/// One `session/prompt` to write: this `promptId`, with `resend`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatPromptRequest {
    pub prompt_id: String,
    pub resend: bool,
    pub attempt: u32,
}

/// How a prompt looks on screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChatPromptLook {
    /// From the tap on.
    Sent,
    /// Unwritten past the quiet threshold: still trying.
    Retrying,
    /// Given up.
    Failed,
}

/// An unwritten prompt handed to the chat's next source, with its tap.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatPromptTaken {
    pub prompt_id: String,
    pub tapped_ms: u64,
}

struct Inner {
    outbox: PromptOutbox,
    /// `now_ms` 0 on the outbox's clock.
    origin: Instant,
}

impl Inner {
    fn at(&self, ms: u64) -> Instant {
        self.origin + Duration::from_millis(ms)
    }

    fn ms(&self, at: Instant) -> u64 {
        u64::try_from(at.saturating_duration_since(self.origin).as_millis()).unwrap_or(u64::MAX)
    }
}

#[derive(uniffi::Object)]
pub struct ChatPromptOutbox {
    inner: Mutex<Inner>,
}

impl ChatPromptOutbox {
    fn inner(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

fn done(done: PromptDone) -> ChatPromptDone {
    let outcome = match done.outcome {
        PromptOutcome::Sent => ChatPromptOutcome::Sent,
        PromptOutcome::Refused { text } => ChatPromptOutcome::Refused { text },
        PromptOutcome::NotSent { text } => ChatPromptOutcome::NotSent { text },
        PromptOutcome::MaybeSent { text } => ChatPromptOutcome::MaybeSent { text },
    };
    ChatPromptDone { prompt_id: done.id, outcome }
}

fn ms_duration(left: Duration) -> u64 {
    u64::try_from(left.as_millis()).unwrap_or(u64::MAX)
}

#[uniffi::export]
impl ChatPromptOutbox {
    /// `hold_ms`: how long a prompt waits for the link before it comes back. `seed`: the retry
    /// jitter's (any value; a random one per source).
    #[uniffi::constructor]
    pub fn new(hold_ms: u64, seed: u64) -> Self {
        Self {
            inner: Mutex::new(Inner {
                outbox: PromptOutbox::new(Duration::from_millis(hold_ms), seed),
                origin: Instant::now(),
            }),
        }
    }

    pub fn set_hold_ms(&self, hold_ms: u64) {
        self.inner().outbox.set_hold(Duration::from_millis(hold_ms));
    }

    /// The link's state; coming back, queued prompts go at once, in order.
    pub fn set_link(&self, up: bool) {
        self.inner().outbox.set_link(up);
    }

    /// A tap on Send, its attachments uploaded. False when this `promptId` is already here.
    pub fn push(&self, prompt_id: String, text: String, resend: bool, tapped_ms: u64, now_ms: u64) -> bool {
        let mut inner = self.inner();
        let (tapped, now) = (inner.at(tapped_ms), inner.at(now_ms));
        inner.outbox.push(prompt_id, text, resend, tapped, now)
    }

    /// The next prompt to write, if one may go now.
    pub fn next_request(&self, now_ms: u64) -> Option<ChatPromptRequest> {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        let request = inner.outbox.next_request(now)?;
        Some(ChatPromptRequest { prompt_id: request.id, resend: request.resend, attempt: request.attempt })
    }

    /// Its write took; its answer is awaited.
    pub fn wrote(&self, prompt_id: String) {
        self.inner().outbox.wrote(&prompt_id);
    }

    /// Its write failed: it goes again after a backoff.
    pub fn write_failed(&self, prompt_id: String, now_ms: u64) {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        inner.outbox.write_failed(&prompt_id, now);
    }

    /// Written, and its answer was lost: it goes again as a resend.
    pub fn lost(&self, prompt_id: String, now_ms: u64) {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        inner.outbox.lost(&prompt_id, now);
    }

    /// The Mac answered it.
    pub fn answered(&self, prompt_id: String) -> Option<ChatPromptDone> {
        self.inner().outbox.answered(&prompt_id).map(done)
    }

    /// The Mac refused it.
    pub fn refused(&self, prompt_id: String) -> Option<ChatPromptDone> {
        self.inner().outbox.refused(&prompt_id).map(done)
    }

    /// Unwritten prompts given up at `now_ms` (all of them once one is past the hold), in order.
    pub fn expire(&self, now_ms: u64) -> Vec<ChatPromptDone> {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        inner.outbox.expire(now).into_iter().map(done).collect()
    }

    /// Gives up on `prompt_id` and every unwritten prompt after it, in order.
    pub fn give_up_from(&self, prompt_id: String) -> Vec<ChatPromptDone> {
        self.inner().outbox.give_up_from(&prompt_id).into_iter().map(done).collect()
    }

    /// Every unwritten prompt, handed over (out of this outbox), in tap order.
    pub fn drain_unwritten(&self) -> Vec<ChatPromptTaken> {
        let mut inner = self.inner();
        let taken = inner.outbox.drain_unwritten();
        taken
            .into_iter()
            .map(|(prompt_id, tapped)| ChatPromptTaken { prompt_id, tapped_ms: inner.ms(tapped) })
            .collect()
    }

    /// How `prompt_id` looks at `now_ms`.
    pub fn look(&self, prompt_id: String, now_ms: u64) -> ChatPromptLook {
        let inner = self.inner();
        match inner.outbox.look(&prompt_id, inner.at(now_ms)) {
            PromptLook::Sent => ChatPromptLook::Sent,
            PromptLook::Retrying => ChatPromptLook::Retrying,
            PromptLook::Failed => ChatPromptLook::Failed,
        }
    }

    /// Forgets a failed prompt's look.
    pub fn forget(&self, prompt_id: String) {
        self.inner().outbox.forget(&prompt_id);
    }

    /// Milliseconds after `now_ms` until something is due (a hold or a retry), or none.
    pub fn next_wake_ms(&self, now_ms: u64) -> Option<u64> {
        let inner = self.inner();
        inner.outbox.next_wake(inner.at(now_ms)).map(ms_duration)
    }

    /// Milliseconds after `now_ms` until a prompt next turns Retrying, or none.
    pub fn next_look_change_ms(&self, now_ms: u64) -> Option<u64> {
        let inner = self.inner();
        inner.outbox.next_look_change(inner.at(now_ms)).map(ms_duration)
    }

    /// The unwritten prompts' ids, in tap order.
    pub fn unwritten(&self) -> Vec<String> {
        self.inner().outbox.unwritten()
    }

    /// Prompts not answered yet.
    pub fn pending(&self) -> u32 {
        u32::try_from(self.inner().outbox.len()).unwrap_or(u32::MAX)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_prompt_sent_offline_goes_in_order_once_the_link_is_back_and_resends_after_a_loss() {
        let outbox = ChatPromptOutbox::new(10_000, 1);
        assert!(outbox.push("a".into(), "first".into(), false, 1_000, 1_000));
        assert!(outbox.push("b".into(), "second".into(), false, 1_001, 1_001));
        assert_eq!(outbox.next_request(1_002), None, "offline: queued");
        assert_eq!(outbox.unwritten(), vec!["a", "b"]);
        outbox.set_link(true);
        let a = outbox.next_request(1_003).unwrap();
        assert_eq!(a, ChatPromptRequest { prompt_id: "a".into(), resend: false, attempt: 1 });
        outbox.wrote("a".into());
        outbox.lost("a".into(), 1_004);
        outbox.set_link(false);
        outbox.set_link(true);
        let again = outbox.next_request(1_005).unwrap();
        assert_eq!(again, ChatPromptRequest { prompt_id: "a".into(), resend: true, attempt: 2 });
        outbox.wrote("a".into());
        assert_eq!(outbox.next_request(1_005).unwrap().prompt_id, "b");
        assert_eq!(
            outbox.answered("a".into()),
            Some(ChatPromptDone { prompt_id: "a".into(), outcome: ChatPromptOutcome::Sent })
        );
    }

    #[test]
    fn the_sources_clock_drives_the_hold_and_the_look() {
        let outbox = ChatPromptOutbox::new(10_000, 1);
        outbox.push("a".into(), "hi".into(), false, 5_000, 5_000);
        assert_eq!(outbox.look("a".into(), 6_999), ChatPromptLook::Sent);
        assert_eq!(outbox.next_look_change_ms(5_000), Some(2_000));
        assert_eq!(outbox.look("a".into(), 7_000), ChatPromptLook::Retrying);
        assert_eq!(outbox.next_wake_ms(14_000), Some(1_000));
        assert!(outbox.expire(14_999).is_empty());
        assert_eq!(
            outbox.expire(15_000),
            vec![ChatPromptDone {
                prompt_id: "a".into(),
                outcome: ChatPromptOutcome::NotSent { text: "hi".into() }
            }]
        );
        assert_eq!(outbox.look("a".into(), 15_000), ChatPromptLook::Failed);
    }

    #[test]
    fn unwritten_prompts_hand_over_with_their_taps() {
        let outbox = ChatPromptOutbox::new(10_000, 1);
        outbox.push("a".into(), "a".into(), false, 2_000, 2_000);
        outbox.push("b".into(), "b".into(), false, 2_500, 2_500);
        assert_eq!(
            outbox.drain_unwritten(),
            vec![
                ChatPromptTaken { prompt_id: "a".into(), tapped_ms: 2_000 },
                ChatPromptTaken { prompt_id: "b".into(), tapped_ms: 2_500 },
            ]
        );
        assert_eq!(outbox.pending(), 0);
    }
}
