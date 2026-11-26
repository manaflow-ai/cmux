//! The agent chat's prompts on their way to the Mac (`cmux_composer_send::chat`): the one send
//! queue for a prompt's text and its attachments. Keyed by `promptId`, written one at a time in
//! tap order once its uploads are on the Mac, a resend once a written one's answer was lost,
//! retried with a jittered, capped backoff, queued while offline and given up past the hold; any
//! pending send can be cancelled, edited, retried now or deleted. Attachments are upload ids
//! (opaque: `AttachmentUploads` starts, retries and tracks each); the Swift chat source reports
//! each upload's end, asks for the next prompt to write, writes it and reports what happened, and
//! cancels the uploads a step names. The outbox decides what goes, as what, and how each prompt
//! looks.
//!
//! One object per chat source, called from the main actor; a mutex keeps it `Sync` for uniffi
//! and is held only for the call. Time is the source's own monotonic clock in milliseconds
//! (`now_ms`, from any origin, never going back), so a test's clock drives the hold too.

use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use cmux_composer_send::chat::{
    Attachment, CancelStep, DEFAULT_HOLD, EditStep, PendingSend, PromptDone, PromptLook, PromptOutbox,
    PromptOutcome, Refusal, ResendState, UploadState, is_transient_refusal,
};

/// How a prompt ended.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ChatPromptOutcome {
    /// The Mac answered it.
    Sent,
    /// The Mac refused it (nothing ran); the source says why in the Mac's words.
    Refused,
    /// It never left before the hold ran out: nothing ran, the text goes back.
    NotSent,
    /// It was written and its answer never came (or it could not be taken off the Mac's queue):
    /// it may have run.
    MaybeSent,
    /// An attachment's upload failed (the uploader gave up): nothing was written.
    UploadFailed { reason: String },
    /// The person cancelled it before it reached the Mac, or the Mac took it off its queue.
    Cancelled,
}

/// Where one attachment's upload is, as reported (its progress is `AttachmentUploads`').
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ChatUploadState {
    Pending,
    Uploaded { mac_path: String },
    Failed { reason: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatAttachment {
    pub upload_id: String,
    pub state: ChatUploadState,
}

/// A prompt that ended, with what the composer may get back.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatPromptDone {
    pub prompt_id: String,
    pub outcome: ChatPromptOutcome,
    pub text: String,
    pub attachments: Vec<ChatAttachment>,
    /// Its uploads not on the Mac yet: the source cancels them (empty for one that went).
    pub cancel_upload_ids: Vec<String>,
}

/// An uploaded attachment a prompt goes with.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatUploadedAttachment {
    pub upload_id: String,
    pub mac_path: String,
}

/// One `session/prompt` to write: this `promptId`, with `resend`, its attachments at their Mac
/// paths.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatPromptRequest {
    pub prompt_id: String,
    pub resend: bool,
    pub attempt: u32,
    pub attachments: Vec<ChatUploadedAttachment>,
}

/// What a cancel or delete asks of the source.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ChatCancelStep {
    /// It never left: back at once (cancel `done.cancel_upload_ids`).
    Returned { done: ChatPromptDone },
    /// It may be on the Mac: call `_acpmux/queue_remove` for it, then `remove_answered`.
    RemoveOnMac { prompt_id: String },
}

/// What an edit did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ChatEditStep {
    /// Edited in place: same id, same place. Cancel the uploads the edit dropped.
    Edited { cancel_upload_ids: Vec<String> },
    /// It may be on the Mac: the edit goes as the new id in its place; remove the old one with
    /// `_acpmux/queue_remove`, then `remove_answered`. Cancel the uploads the edit dropped.
    Replaced { remove_prompt_id: String, cancel_upload_ids: Vec<String> },
}

/// How a prompt looks on screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChatPromptLook {
    /// From the tap on.
    Sent,
    /// Unwritten past the quiet threshold after its uploads: still trying.
    Retrying,
    /// Given up.
    Failed,
}

/// A prompt still on its way, as the chat draws its row, with the actions it has: Stop (its
/// text back in the composer to edit and send again) and Delete always, Send now when offered.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatPendingSend {
    pub prompt_id: String,
    pub text: String,
    /// Its attachments' upload ids.
    pub upload_ids: Vec<String>,
    pub look: ChatPromptLook,
    /// Until it goes again after a "not now", when it waits on one.
    pub retry_in_ms: Option<u64>,
    /// The chat shows its row (attachments, waiting, or being stopped).
    pub shown: bool,
    /// Send now is offered (link up, unwritten, waiting).
    pub can_send_now: bool,
    /// Stopped after it may have reached the Mac: the Mac's removal is awaited.
    pub stopping: bool,
}

fn chat_look(look: PromptLook) -> ChatPromptLook {
    match look {
        PromptLook::Sent => ChatPromptLook::Sent,
        PromptLook::Retrying => ChatPromptLook::Retrying,
        PromptLook::Failed => ChatPromptLook::Failed,
    }
}

fn pending_send(p: PendingSend) -> ChatPendingSend {
    ChatPendingSend {
        prompt_id: p.id,
        text: p.text,
        upload_ids: p.attachments,
        look: chat_look(p.look),
        retry_in_ms: p.retry_in.map(ms_duration),
        shown: p.shown,
        can_send_now: p.can_send_now,
        stopping: p.stopping,
    }
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

/// What to do after the Mac answered a prompt with an error.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ChatRefusal {
    /// The Mac said "not now" (starting, busy, restarting, ...): the prompt goes again after
    /// `retry_in_ms` (attempt `attempt` of the retries) and keeps looking sent or retrying.
    Retry { attempt: u32, retry_in_ms: u64 },
    /// A real refusal: the prompt is given back; its error text is the Mac's own.
    Final { done: ChatPromptDone },
}

/// The quiet window a chat's outbox starts with, in milliseconds: how long a prompt may go with
/// no progress at all before it comes back (one place for every source's default).
#[uniffi::export]
pub fn chat_prompt_default_hold_ms() -> u64 {
    ms_duration(DEFAULT_HOLD)
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

fn attachment(a: Attachment) -> ChatAttachment {
    let state = match a.state {
        UploadState::Pending => ChatUploadState::Pending,
        UploadState::Uploaded { mac_path } => ChatUploadState::Uploaded { mac_path },
        UploadState::Failed { reason } => ChatUploadState::Failed { reason },
    };
    ChatAttachment { upload_id: a.id, state }
}

fn done(done: PromptDone) -> ChatPromptDone {
    let outcome = match done.outcome {
        PromptOutcome::Sent => ChatPromptOutcome::Sent,
        PromptOutcome::Refused => ChatPromptOutcome::Refused,
        PromptOutcome::NotSent => ChatPromptOutcome::NotSent,
        PromptOutcome::MaybeSent => ChatPromptOutcome::MaybeSent,
        PromptOutcome::UploadFailed { reason } => ChatPromptOutcome::UploadFailed { reason },
        PromptOutcome::Cancelled => ChatPromptOutcome::Cancelled,
    };
    ChatPromptDone {
        prompt_id: done.id,
        outcome,
        text: done.text,
        attachments: done.attachments.into_iter().map(attachment).collect(),
        cancel_upload_ids: done.cancel_uploads,
    }
}

fn cancel_step(step: CancelStep) -> ChatCancelStep {
    match step {
        CancelStep::Returned(d) => ChatCancelStep::Returned { done: done(d) },
        CancelStep::RemoveOnMac { id } => ChatCancelStep::RemoveOnMac { prompt_id: id },
    }
}

fn ms_duration(left: Duration) -> u64 {
    u64::try_from(left.as_millis()).unwrap_or(u64::MAX)
}

#[uniffi::export]
impl ChatPromptOutbox {
    /// `hold_ms`: how long a prompt may go with no progress (see `progressed`) before it comes back. `seed`: the retry
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

    /// The link's state at `now_ms`; coming back, queued prompts go at once, in order.
    pub fn set_link(&self, up: bool, now_ms: u64) {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        inner.outbox.set_link(up, now);
    }

    /// A tap on Send with its attachments' upload ids (started at pick time). Never waits. False
    /// when this `promptId` is already here.
    pub fn push(
        &self,
        prompt_id: String,
        text: String,
        upload_ids: Vec<String>,
        resend: bool,
        tapped_ms: u64,
        now_ms: u64,
    ) -> bool {
        let mut inner = self.inner();
        let (tapped, now) = (inner.at(tapped_ms), inner.at(now_ms));
        inner.outbox.push(prompt_id, text, upload_ids, resend, tapped, now)
    }

    /// The link made progress at `now_ms` (bytes heard from the Mac, a channel bound, a write
    /// taken): prompts waiting their turn keep going; the hold bounds a stall, not a send.
    pub fn progressed(&self, now_ms: u64) {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        inner.outbox.progressed(now);
    }

    /// The upload `upload_id` took a chunk at `now_ms`: its prompt keeps going.
    pub fn upload_progressed(&self, upload_id: String, now_ms: u64) {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        inner.outbox.upload_progressed(&upload_id, now);
    }

    /// The upload `upload_id` ended on the Mac at `mac_path`. Unknown ids are ignored.
    pub fn uploaded(&self, upload_id: String, mac_path: String, now_ms: u64) {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        inner.outbox.uploaded(&upload_id, mac_path, now);
    }

    /// The uploader gave up on `upload_id`: the prompt holding it, given up (`UploadFailed`),
    /// with its other uploads to cancel.
    pub fn upload_failed(&self, upload_id: String, reason: String) -> Option<ChatPromptDone> {
        self.inner().outbox.upload_failed(&upload_id, reason).map(done)
    }

    /// The next prompt to write, if one may go now.
    pub fn next_request(&self, now_ms: u64) -> Option<ChatPromptRequest> {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        let request = inner.outbox.next_request(now)?;
        Some(ChatPromptRequest {
            prompt_id: request.id,
            resend: request.resend,
            attempt: request.attempt,
            attachments: request
                .attachments
                .into_iter()
                .map(|(upload_id, mac_path)| ChatUploadedAttachment { upload_id, mac_path })
                .collect(),
        })
    }

    /// Its write took; its answer is awaited.
    pub fn wrote(&self, prompt_id: String) {
        self.inner().outbox.wrote(&prompt_id);
    }

    /// Its write failed: it goes again after a backoff, its wait aged from the failure (first) or moved on by what the write took.
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

    /// The Mac answered it with an error (`origin`, `code`, `reason`: `error.data`'s). A "not now"
    /// (Rust tells: starting, busy, restarting, timed out, native origin ...) is retried after a
    /// backoff of 1 s doubling to 30 s and is not final; only a real refusal gives the prompt
    /// back. `None` when the prompt is not here.
    pub fn refusal(
        &self,
        prompt_id: String,
        origin: Option<String>,
        code: Option<String>,
        reason: Option<String>,
        now_ms: u64,
    ) -> Option<ChatRefusal> {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        let transient = is_transient_refusal(origin.as_deref(), code.as_deref(), reason.as_deref());
        Some(match inner.outbox.refusal(&prompt_id, transient, now)? {
            Refusal::Retry { attempt, retry_in } => {
                ChatRefusal::Retry { attempt, retry_in_ms: ms_duration(retry_in) }
            }
            Refusal::Final(d) => ChatRefusal::Final { done: done(d) },
        })
    }

    /// The Mac's `_cmux/prompt_resend` notice for this prompt: `state` is `sent`, `accepted`,
    /// `retrying` (with `retry_in_ms`) or `refused`. A refusal gives the prompt back (`Some`); the
    /// others only change its look. An unknown state is ignored.
    pub fn resend_notice(
        &self,
        prompt_id: String,
        state: String,
        retry_in_ms: Option<u64>,
        now_ms: u64,
    ) -> Option<ChatPromptDone> {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        let state = ResendState::parse(&state, retry_in_ms)?;
        inner.outbox.resend_notice(&prompt_id, state, now).map(done)
    }

    /// How long until the prompt goes again after a "not now", or none.
    pub fn retry_in_ms(&self, prompt_id: String, now_ms: u64) -> Option<u64> {
        let inner = self.inner();
        inner.outbox.retry_in(&prompt_id, inner.at(now_ms)).map(ms_duration)
    }

    /// The person cancels it, at any point.
    pub fn cancel(&self, prompt_id: String) -> Option<ChatCancelStep> {
        self.inner().outbox.cancel(&prompt_id).map(cancel_step)
    }

    /// The Mac's answer to `_acpmux/queue_remove`: `removed` from its queue, or not.
    pub fn remove_answered(&self, prompt_id: String, removed: bool) -> Option<ChatPromptDone> {
        self.inner().outbox.remove_answered(&prompt_id, removed).map(done)
    }

    /// Cancel without a failed mark left behind.
    pub fn delete(&self, prompt_id: String) -> Option<ChatCancelStep> {
        self.inner().outbox.delete(&prompt_id).map(cancel_step)
    }

    /// The person edits it: in place, or (it may be on the Mac) as `new_prompt_id` in its place.
    pub fn edit(
        &self,
        prompt_id: String,
        new_prompt_id: String,
        text: String,
        upload_ids: Vec<String>,
        now_ms: u64,
    ) -> Option<ChatEditStep> {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        Some(match inner.outbox.edit(&prompt_id, new_prompt_id, text, upload_ids, now)? {
            EditStep::Edited { cancel_uploads } => ChatEditStep::Edited { cancel_upload_ids: cancel_uploads },
            EditStep::Replaced { remove, cancel_uploads } => {
                ChatEditStep::Replaced { remove_prompt_id: remove, cancel_upload_ids: cancel_uploads }
            }
        })
    }

    /// The person asks it to go now. False when it is not an unwritten prompt here.
    pub fn retry_now(&self, prompt_id: String, now_ms: u64) -> bool {
        let mut inner = self.inner();
        let now = inner.at(now_ms);
        inner.outbox.retry_now(&prompt_id, now)
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

    /// Every unwritten prompt that never left, handed over (out of this outbox), in tap order.
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
        chat_look(inner.outbox.look(&prompt_id, inner.at(now_ms)))
    }

    /// Every prompt still on its way at `now_ms`, in tap order, with the actions each has: the
    /// chat's pending rows (no pending send is ever without an exit).
    pub fn pending_sends(&self, now_ms: u64) -> Vec<ChatPendingSend> {
        let inner = self.inner();
        inner.outbox.pending(inner.at(now_ms)).into_iter().map(pending_send).collect()
    }

    /// Its attachments and their uploads' ends, or none.
    pub fn attachments(&self, prompt_id: String) -> Option<Vec<ChatAttachment>> {
        Some(self.inner().outbox.attachments(&prompt_id)?.into_iter().map(attachment).collect())
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

    /// Prompts not ended yet.
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
        assert!(outbox.push("a".into(), "first".into(), vec![], false, 1_000, 1_000));
        assert!(outbox.push("b".into(), "second".into(), vec![], false, 1_001, 1_001));
        assert_eq!(outbox.next_request(1_002), None, "offline: queued");
        assert_eq!(outbox.unwritten(), vec!["a", "b"]);
        outbox.set_link(true, 1_002);
        let a = outbox.next_request(1_003).unwrap();
        assert_eq!(
            a,
            ChatPromptRequest { prompt_id: "a".into(), resend: false, attempt: 1, attachments: vec![] }
        );
        outbox.wrote("a".into());
        outbox.lost("a".into(), 1_004);
        outbox.set_link(false, 1_004);
        outbox.set_link(true, 1_002);
        let again = outbox.next_request(1_005).unwrap();
        assert_eq!(
            again,
            ChatPromptRequest { prompt_id: "a".into(), resend: true, attempt: 2, attachments: vec![] }
        );
        outbox.wrote("a".into());
        assert_eq!(outbox.next_request(1_005).unwrap().prompt_id, "b");
        assert_eq!(
            outbox.answered("a".into()),
            Some(ChatPromptDone {
                prompt_id: "a".into(),
                outcome: ChatPromptOutcome::Sent,
                text: "first".into(),
                attachments: vec![],
                cancel_upload_ids: vec![]
            })
        );
    }

    #[test]
    fn the_sources_clock_drives_the_hold_and_the_look() {
        let outbox = ChatPromptOutbox::new(10_000, 1);
        outbox.push("a".into(), "hi".into(), vec![], false, 5_000, 5_000);
        assert_eq!(outbox.look("a".into(), 6_999), ChatPromptLook::Sent);
        assert_eq!(outbox.next_look_change_ms(5_000), Some(2_000));
        assert_eq!(outbox.look("a".into(), 7_000), ChatPromptLook::Retrying);
        assert_eq!(outbox.next_wake_ms(14_000), Some(1_000));
        assert!(outbox.expire(14_999).is_empty());
        assert_eq!(
            outbox.expire(15_000),
            vec![ChatPromptDone {
                prompt_id: "a".into(),
                outcome: ChatPromptOutcome::NotSent,
                text: "hi".into(),
                attachments: vec![],
                cancel_upload_ids: vec![]
            }]
        );
        assert_eq!(outbox.look("a".into(), 15_000), ChatPromptLook::Failed);
    }

    #[test]
    fn unwritten_prompts_hand_over_with_their_taps() {
        let outbox = ChatPromptOutbox::new(10_000, 1);
        outbox.push("a".into(), "a".into(), vec![], false, 2_000, 2_000);
        outbox.push("b".into(), "b".into(), vec![], false, 2_500, 2_500);
        assert_eq!(
            outbox.drain_unwritten(),
            vec![
                ChatPromptTaken { prompt_id: "a".into(), tapped_ms: 2_000 },
                ChatPromptTaken { prompt_id: "b".into(), tapped_ms: 2_500 },
            ]
        );
        assert_eq!(outbox.pending(), 0);
    }

    #[test]
    fn cancel_mid_upload_hands_text_and_attachments_back_at_once_with_the_upload_to_cancel() {
        let outbox = ChatPromptOutbox::new(10_000, 1);
        outbox.set_link(true, 0);
        assert!(outbox.push("a".into(), "pic".into(), vec!["x".into()], false, 0, 0));
        assert_eq!(
            outbox.cancel("a".into()),
            Some(ChatCancelStep::Returned {
                done: ChatPromptDone {
                    prompt_id: "a".into(),
                    outcome: ChatPromptOutcome::Cancelled,
                    text: "pic".into(),
                    attachments: vec![ChatAttachment {
                        upload_id: "x".into(),
                        state: ChatUploadState::Pending
                    }],
                    cancel_upload_ids: vec!["x".into()],
                }
            })
        );
        assert_eq!(outbox.pending(), 0);
    }

    #[test]
    fn a_written_prompt_is_edited_as_a_new_one_and_removed_on_the_mac() {
        let outbox = ChatPromptOutbox::new(10_000, 1);
        outbox.set_link(true, 0);
        outbox.push("a".into(), "old".into(), vec!["x".into()], false, 0, 0);
        outbox.uploaded("x".into(), "/m/x".into(), 1);
        let r = outbox.next_request(1).unwrap();
        assert_eq!(
            r.attachments,
            vec![ChatUploadedAttachment { upload_id: "x".into(), mac_path: "/m/x".into() }]
        );
        outbox.wrote("a".into());
        assert_eq!(
            outbox.edit("a".into(), "a2".into(), "new".into(), vec!["x".into()], 2),
            Some(ChatEditStep::Replaced { remove_prompt_id: "a".into(), cancel_upload_ids: vec![] })
        );
        assert_eq!(outbox.next_request(2).unwrap().attachments.len(), 1, "x kept its upload");
        assert_eq!(outbox.remove_answered("a".into(), false).unwrap().outcome, ChatPromptOutcome::MaybeSent);
        assert!(!outbox.retry_now("a2".into(), 3), "a2 is being written");
    }

    #[test]
    fn a_not_now_refusal_retries_and_a_real_one_gives_the_prompt_back() {
        assert_eq!(chat_prompt_default_hold_ms(), 30_000);
        let outbox = ChatPromptOutbox::new(chat_prompt_default_hold_ms(), 1);
        outbox.set_link(true, 1_000);
        assert!(outbox.push("a".into(), "hi".into(), vec![], false, 1_000, 1_000));
        outbox.next_request(1_000).unwrap();
        outbox.wrote("a".into());
        let busy =
            outbox.refusal("a".into(), None, Some("-32000".into()), Some("hub.starting".into()), 2_000);
        assert_eq!(busy, Some(ChatRefusal::Retry { attempt: 1, retry_in_ms: 1_000 }));
        assert_eq!(outbox.look("a".into(), 2_000), ChatPromptLook::Retrying);
        assert_eq!(outbox.retry_in_ms("a".into(), 2_400), Some(600));
        assert_eq!(outbox.next_request(2_999), None);
        assert!(outbox.next_request(3_000).unwrap().resend);
        outbox.wrote("a".into());
        let native =
            outbox.refusal("a".into(), Some("native".into()), Some("timed_out".into()), None, 40_000);
        assert_eq!(
            native,
            Some(ChatRefusal::Retry { attempt: 2, retry_in_ms: 2_000 }),
            "past 10 s, not given back"
        );
        let real = outbox.refusal("a".into(), None, None, Some("remote.full_access_required".into()), 42_000);
        let Some(ChatRefusal::Final { done }) = real else { panic!("a real refusal is final: {real:?}") };
        assert_eq!(done.outcome, ChatPromptOutcome::Refused);
        assert_eq!(done.text, "hi");
        assert_eq!(outbox.refusal("a".into(), None, None, None, 43_000), None);
    }

    #[test]
    fn the_macs_resend_notices_change_the_look_and_a_refusal_ends_it() {
        let outbox = ChatPromptOutbox::new(30_000, 1);
        outbox.set_link(true, 1_000);
        outbox.push("a".into(), "hi".into(), vec![], false, 1_000, 1_000);
        outbox.next_request(1_000).unwrap();
        outbox.wrote("a".into());
        assert_eq!(outbox.resend_notice("a".into(), "retrying".into(), Some(4_000), 2_000), None);
        assert_eq!(outbox.look("a".into(), 2_000), ChatPromptLook::Retrying);
        assert_eq!(outbox.retry_in_ms("a".into(), 2_000), Some(4_000));
        assert_eq!(outbox.resend_notice("a".into(), "accepted".into(), None, 3_000), None);
        assert_eq!(outbox.look("a".into(), 3_000), ChatPromptLook::Sent);
        assert_eq!(outbox.resend_notice("a".into(), "weird".into(), None, 3_000), None);
        let refused = outbox.resend_notice("a".into(), "refused".into(), None, 4_000).unwrap();
        assert_eq!(refused.outcome, ChatPromptOutcome::Refused);
    }
}
