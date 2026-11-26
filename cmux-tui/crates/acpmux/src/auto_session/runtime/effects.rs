//! What the loop does for each effect of a step, and what comes back of the work it started.

use std::sync::Arc;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::holder::{self, Change, Effect, Event};
use cmux_auto_session::wire::ErrorCode;

use super::chats::LaneOp;
use super::run::Loop;
use crate::auto_session::export::Copied;
use crate::auto_session::export::snapshot::Failed;
use crate::auto_session::record::{AutoRecord, Leftover};
use crate::auto_session::{ImportError, Imported};
use crate::hub::Session;

#[cfg(unix)]
const STOP: i32 = libc::SIGSTOP;
#[cfg(unix)]
const CONTINUE: i32 = libc::SIGCONT;
#[cfg(not(unix))]
const STOP: i32 = 0;
#[cfg(not(unix))]
const CONTINUE: i32 = 0;

impl<C: AutoCloud + 'static> Loop<C> {
    /// One effect. What touches the chat's processes is done before this returns; what calls
    /// the store starts a task, or waits its turn in the chat's lane.
    pub(super) async fn effect(
        &mut self,
        id: &str,
        session: Option<&Arc<Session>>,
        effect: Effect,
    ) {
        let chat = id.to_owned();
        match effect {
            Effect::Register { request } => {
                let keep = session
                    .and_then(|session| self.hub.auto_record(session))
                    .map(|record| record.keep_in_cloud);
                let task = self.ctx.clone().register(chat, request, keep);
                self.ctx.start("auto-session register", task);
            }
            Effect::Renew { request, epoch, needs_run, standby } => {
                let task = self.ctx.clone().renew(chat, request, epoch, needs_run, standby);
                self.ctx.start("auto-session renew", task);
            }
            Effect::Close => {
                self.ctx.start("auto-session close", self.ctx.clone().close(chat));
            }
            Effect::StopTree => {
                if let Some(session) = session {
                    let stopped = self.hub.auto_signal_tree(session, STOP).await;
                    tracing::info!(session = %id, stopped, "auto session: process tree stopped");
                }
            }
            Effect::ContinueTree => {
                if let Some(session) = session {
                    self.hub.auto_signal_tree(session, CONTINUE).await;
                }
            }
            Effect::KillTree => {
                if let Some(session) = session {
                    let killed = self.hub.auto_kill_tree(session).await;
                    tracing::info!(session = %id, killed, "auto session: process tree killed");
                }
                if let Some(tracked) = self.chats.get_mut(id) {
                    tracked.tool = None;
                }
            }
            Effect::WriteLeftoverPatch => {
                self.lane(id, LaneOp::Leftover);
                self.unsent(id);
            }
            // The copy sends the events ahead of its snapshot (`export::copy`).
            Effect::UploadEvents { .. } => {}
            Effect::UploadSnapshot { epoch, copy } => self.copy(id, epoch, copy),
            Effect::DrainInbox => self.lane(id, LaneOp::Drain),
            Effect::Import { reason, epoch } => {
                // Once more before the chat here is replaced, for a send that did not arrive.
                self.unsent(id);
                self.lane(id, LaneOp::Import { reason, epoch });
            }
            Effect::AckAssignment { epoch } => self.lane(id, LaneOp::Ack { epoch }),
            // A chat the person moved (`give.rs`).
            Effect::StopTurn => self.stop_turn(id),
            Effect::Give { epoch } => self.give(id, epoch),
            Effect::Stay => self.stay(id),
            Effect::NotMoved { to, why } => self.not_moved(id, to, why),
            // The row reads `Chat::blocked` when the record is written (`chats.rs`).
            Effect::ShowBlocked { .. } => {}
            Effect::ScheduleAt { at } => {
                if let Some(tracked) = self.chats.get_mut(id) {
                    tracked.timer = Some(at);
                }
            }
        }
    }

    /// Starts a copy, or keeps it as the next one while another is on its way: a newer copy
    /// replaces one that waits.
    ///
    /// A give's copy is the last the next holder gets of the chat, so it also waits for what
    /// the chat's lane is in the middle of: an inbox message taken a moment ago is written to
    /// the log and then acked, and a copy read between the two would leave it in neither the
    /// copy nor the inbox. No drain starts in the lane of a chat that is given (`run_lane`;
    /// what else may start there writes nothing to the log and ends by itself), and the
    /// lane's end starts the copy (`lane_done`).
    fn copy(&mut self, id: &str, epoch: u64, copy: u64) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        let lane_writes = tracked.lane_busy && tracked.chat.moving().is_some();
        if tracked.copying.is_some() || lane_writes {
            tracked.wanted = Some(copy);
            return;
        }
        // Copies are asked for in order: one that still waits is older than this one.
        tracked.wanted = None;
        tracked.copying = Some(epoch);
        let (after, tool) = (tracked.sent, tracked.tool.clone());
        let task = self.ctx.clone().copy(id.to_owned(), epoch, copy, after, tool);
        self.ctx.start("auto-session copy", task);
    }

    /// A copy ended: the state machine hears of it, and the next one that waits starts.
    pub(super) async fn copied(
        &mut self,
        id: &str,
        copy: u64,
        result: Result<Copied, (Option<u64>, Failed)>,
    ) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        let sent_at_epoch = tracked.copying.take();
        let wanted = tracked.wanted.take();
        let copied_ok = result.is_ok();
        let (mut lost, mut outdated) = (false, false);
        let event = match result {
            Ok(copied) => {
                tracked.sent = copied.last_seq;
                tracked.own = Some(copied.last_seq);
                tracked.anchor = copied.stored.anchor;
                Event::SnapshotStored { copy, snapshot: copied.stored.snapshot }
            }
            Err((stored, failed)) => {
                if let Some(stored) = stored {
                    tracked.sent = stored;
                    tracked.own = Some(stored);
                }
                if let Failed::Cloud(error) = &failed
                    && matches!(error.code(), Some(ErrorCode::StaleEpoch | ErrorCode::NotHolder))
                {
                    // A copy sent at an epoch the chat has left says nothing the store's
                    // answer since did not: only a refusal at the chat's own epoch is news.
                    outdated = sent_at_epoch != tracked.chat.epoch();
                    lost = !outdated;
                }
                tracing::info!(session = %id, "auto session: a copy did not get there: {failed}");
                Event::SnapshotFailed { copy, too_large: failed.too_large() }
            }
        };
        self.step(id, event).await;
        if lost {
            // The store refused the write as another holder's: stop and ask, as on a wake.
            self.step(id, Event::Wake).await;
        }
        let Some(chat) = self.chats.get(id).map(|tracked| tracked.chat) else { return };
        // A holder in the middle of a give still copies: the give waits for the copy that
        // covers the chat's last event, which may be one asked for while another was sent.
        let copies = chat.may_run() || chat.moving().is_some();
        let Some(epoch) = chat.epoch().filter(|_| copies) else { return };
        match wanted {
            Some(copy) => {
                self.copy(id, epoch, copy);
                // If the chat cannot copy at this point (for example, a laptop stopped on a
                // wake), the queued copy is discarded. The completed copy is then the newest
                // one that exists, so do not leave the holder in `Sending` for a copy that has
                // no task behind it. A failed copy remains retryable on its next tick.
                if let Some(tracked) = self.chats.get_mut(id)
                    && tracked.copying.is_none()
                    && tracked.wanted.is_none()
                    && tracked.chat.copy == holder::CopyState::Sending
                {
                    tracked.chat.copy = if copied_ok {
                        holder::CopyState::Stored
                    } else {
                        holder::CopyState::Failed
                    };
                }
            }
            // The copy is still owed, at the epoch the chat runs at now.
            None if outdated && chat.may_run() => self.read_work(id, Some(Change::QueueChanged)),
            None => {}
        }
    }

    /// A laptop that lost the chat, or brings its Cloud copy in, sends the Cloud inbox what
    /// the person queued here that the store never had, so the chat's holder runs it once. A
    /// takeover goes on from the store's copy, and an import replaces the chat here with it:
    /// without this such a prompt would run nowhere.
    fn unsent(&mut self, id: &str) {
        if self.side != holder::Side::Laptop {
            return;
        }
        if let Some(after) = self.chats.get(id).and_then(|tracked| tracked.own) {
            self.lane(id, LaneOp::Unsent { after });
        }
    }

    /// Queues one thing in the chat's lane and starts it when the lane is free.
    pub(super) fn lane(&mut self, id: &str, op: LaneOp) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        // One drain that waits is enough: it takes whatever the inbox holds when it runs.
        if op == LaneOp::Drain && tracked.lane.contains(&LaneOp::Drain) {
            return;
        }
        tracked.lane.push_back(op);
        self.run_lane(id);
    }

    fn run_lane(&mut self, id: &str) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        if tracked.lane_busy {
            return;
        }
        let op = loop {
            let Some(op) = tracked.lane.pop_front() else { return };
            // The inbox is the holder's to take: a chat that may not run here now takes it
            // when it may again (`run.rs` `settle`).
            if op != LaneOp::Drain || tracked.chat.may_run() {
                break op;
            }
        };
        tracked.lane_busy = true;
        let (epoch, view, anchor) =
            (tracked.chat.epoch(), tracked.view.clone(), tracked.anchor.clone());
        let task = self.ctx.clone().lane(id.to_owned(), op, epoch, view, anchor);
        self.ctx.start("auto-session lane", task);
    }

    /// The lane finished one thing. After a drain the chat's work is read, so the messages it
    /// took are in the next copy.
    pub(super) fn lane_done(&mut self, id: &str, drained: bool) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        tracked.lane_busy = false;
        let chat = tracked.chat;
        // The copy that waited for the lane (`copy`), when the chat still copies.
        let waited = match tracked.copying {
            None => tracked.wanted.take(),
            Some(_) => None,
        };
        if drained && chat.may_run() {
            self.read_work(id, Some(Change::QueueChanged));
        }
        let copies = chat.may_run() || chat.moving().is_some();
        if let (Some(copy), Some(epoch)) = (waited, chat.epoch().filter(|_| copies)) {
            self.copy(id, epoch, copy);
        }
        self.run_lane(id);
        self.forget_spent(id);
    }

    /// An import ended.
    pub(super) async fn imported(
        &mut self,
        id: &str,
        epoch: u64,
        result: Result<Imported, ImportError>,
    ) {
        let mut accepted = false;
        let event = match result {
            Ok(imported) => {
                let done = Event::ImportDone { epoch: imported.epoch, snapshot: imported.snapshot };
                // Decided before anything changes: this import is the chat's now only when the
                // state machine takes it (this epoch, a lease heard from lately).
                let now = self.now();
                accepted = imported.session_id == id
                    && self.chats.get(id).is_some_and(|tracked| {
                        let (after, _) = holder::step(tracked.chat, done, now);
                        after.may_run() && after.epoch() == Some(imported.epoch)
                    });
                if let Some(tracked) = self.chats.get_mut(id).filter(|_| accepted) {
                    // The chat's log here is the store's now, and the folder is the snapshot's:
                    // the next copy sets the tree a leftover patch is cut against.
                    tracked.sent = imported.last_seq;
                    tracked.own = Some(imported.last_seq);
                    tracked.anchor = None;
                    tracked.tool = None;
                    // The import made the chat a session of this daemon.
                    tracked.absent = false;
                    // A task that waits on the session the import replaced waits on nothing
                    // of this one (`settle.rs`).
                    tracked.settling = false;
                }
                self.give_forgotten(id);
                done
            }
            Err(error) => {
                tracing::warn!(session = %id, "auto session: {error}");
                Event::ImportFailed { epoch }
            }
        };
        self.step(id, event).await;
        // The import was accepted and the chat may run: its hold ends and its queue runs, once.
        // Any other result leaves the chat frozen as it was.
        if accepted
            && self.chats.get(id).is_some_and(|tracked| tracked.chat.may_run())
            && let Some(session) = self.hub.auto_session(id)
        {
            self.hub.auto_activate(&session);
        }
    }

    /// The leftover patch was written: the chat's record names it until the person settles it.
    pub(super) fn leftover_written(&mut self, id: &str, result: Result<Option<Leftover>, String>) {
        let leftover = match result {
            Ok(Some(leftover)) => leftover,
            Ok(None) => return,
            Err(error) => {
                tracing::warn!(session = %id, "auto session: no leftover patch: {error}");
                return;
            }
        };
        let Some(session) = self.hub.auto_session(id) else { return };
        self.hub.update_auto_record(&session, |old| {
            let mut record = old.unwrap_or_else(|| AutoRecord { auto: false, ..AutoRecord::on() });
            record.leftover = Some(leftover);
            Some(record)
        });
    }
}
