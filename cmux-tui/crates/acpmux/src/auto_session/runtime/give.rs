//! A give: the person moved a chat this machine holds, and the holder hands it over
//! (`cmux_auto_session::holder::give`). What the loop does for the four effects of one:
//!
//! - `StopTurn`: the turn that runs is stopped as a move by hand interrupts one
//!   (`hub/auto_give.rs`). Its continuation is in the log by then, so the copy that follows
//!   carries it and the turn goes on where the chat lands. The chat is frozen for the whole
//!   give; a prompt sent meanwhile goes to the chat's Cloud inbox (`switch.rs`).
//! - `Give`: the store is asked to take the chat.
//! - `Stay`: the give did not happen. The continuation runs here once the chat may run again,
//!   told that the chat stayed.
//! - `NotMoved`: the chat's log says, once, why it was not moved.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::holder::{Change, Declined, Event, GiveFailure};
use cmux_auto_session::wire::MoveTo;

use super::run::Loop;
use super::tasks::{Ctx, answered};
use crate::hub::TurnStop;

/// What a give keeps of the turn it stopped.
#[derive(Debug, Default)]
pub(super) struct Stopped {
    /// A `StopTurn` is on its way.
    stopping: bool,
    /// The continuation logged for the turn that was stopped: its prompt id. It is not in the
    /// chat's queue here: it goes with the copy, or joins the queue when the chat stays.
    carried: Option<String>,
    /// The give ended with the chat still here: the continuation is owed to the queue.
    stay: bool,
}

/// Why a chat was not moved, for the person.
fn not_moved_text(to: MoveTo, why: Declined) -> String {
    let place = match to {
        MoveTo::Cloud => "the Cloud",
        MoveTo::Local => "your computer",
    };
    let reason = match (why, to) {
        (Declined::TooLarge, _) => "it is too large to copy",
        (Declined::Stuck, _) => "the turn that was running did not stop; try again once it ends",
        (Declined::Refused, MoveTo::Cloud) => "there is no Cloud machine to run it on",
        (Declined::Refused, MoveTo::Local) => "none of your computers is standing by to take it",
    };
    format!("This chat was not moved to {place}: {reason}. It goes on where it is.")
}

impl<C: AutoCloud + 'static> Loop<C> {
    /// `StopTurn`. One stop runs at a time: a give that starts while the last one's stop is
    /// still on its way is answered by that stop.
    pub(super) fn stop_turn(&mut self, id: &str) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        tracked.give.stay = false;
        if tracked.give.stopping {
            return;
        }
        tracked.give.stopping = true;
        self.ctx.start("auto-session stop turn", self.ctx.clone().stop_turn(id.to_owned()));
    }

    /// `Give`.
    pub(super) fn give(&mut self, id: &str, epoch: u64) {
        self.ctx.start("auto-session give", self.ctx.clone().give(id.to_owned(), epoch));
    }

    /// `Stay`: the turn the give stopped goes on here. It is queued once the chat may run
    /// ([`Self::carried_settles`]): the step that asked may leave the chat stopped.
    pub(super) fn stay(&mut self, id: &str) {
        if let Some(tracked) = self.chats.get_mut(id) {
            tracked.give.stay = true;
        }
    }

    /// `NotMoved`.
    pub(super) fn not_moved(&mut self, id: &str, to: MoveTo, why: Declined) {
        let text = not_moved_text(to, why);
        tracing::info!(session = %id, why = why.as_str(), "auto session: {text}");
        if let Some(session) = self.hub.auto_session(id) {
            self.hub.auto_tell_not_moved(&session, to.as_str(), why.as_str(), &text);
        }
    }

    /// A `StopTurn` ended. The state machine hears the chat's work first, so what it tells the
    /// store of the chat counts the turn that was cut off.
    pub(super) async fn turn_stopped(&mut self, id: &str, stop: TurnStop, needs_run: bool) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        tracked.give.stopping = false;
        tracked.give.carried = stop.carried;
        tracked.tool = None;
        self.step(id, Event::Changed { change: Change::QueueChanged, needs_run }).await;
        let event = if stop.stopped {
            Event::TurnStopped
        } else {
            Event::GiveFailed { why: GiveFailure::Stuck }
        };
        self.step(id, event).await;
        self.carried_settles(id);
    }

    /// What becomes of the continuation a give logged, as the chat stands now. Another
    /// holder's chat: it went with the copy. A chat that stayed and may run: it joins the queue
    /// here, at its head. Otherwise it waits.
    pub(super) fn carried_settles(&mut self, id: &str) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        if tracked.give.stopping {
            return;
        }
        let chat = tracked.chat;
        if !chat.here() && !chat.may_run() {
            tracked.give = Stopped::default();
            return;
        }
        if !tracked.give.stay || !chat.may_run() {
            return;
        }
        tracked.give.stay = false;
        let Some(carried) = tracked.give.carried.take() else { return };
        let Some(session) = self.hub.auto_session(id) else { return };
        self.hub.auto_stay(&session, &carried);
    }

    /// An import replaced the chat: nothing of a give before it is owed.
    pub(super) fn give_forgotten(&mut self, id: &str) {
        if let Some(tracked) = self.chats.get_mut(id) {
            let stopping = tracked.give.stopping;
            tracked.give = Stopped { stopping, ..Stopped::default() };
        }
    }
}

impl<C: AutoCloud + 'static> Ctx<C> {
    /// `StopTurn`: stops the chat's turn and reads its work as it is then. A chat that is not
    /// on this machine runs nothing.
    async fn stop_turn(self, id: String) {
        let (stop, needs_run) = match self.session(&id) {
            Some(session) => {
                let stop = self.hub.auto_stop_turn(&session).await;
                let hub = self.hub.clone();
                // Off the async workers: it reads process records.
                let at_work = tokio::task::spawn_blocking(move || hub.auto_needs_run(&session))
                    .await
                    .unwrap_or(false);
                let needs_run = at_work || stop.carried.is_some();
                (stop, needs_run)
            }
            None => (TurnStop { stopped: true, carried: None }, false),
        };
        self.tell(super::Command::TurnStopped { id, stop, needs_run });
    }

    /// `Give`: `POST /:id/give` at `epoch`. The loop gets the store's view with its answer.
    async fn give(self, id: String, epoch: u64) {
        let result = answered(self.cloud.give(&id, &self.fence(epoch))).await;
        if let Err(error) = &result {
            tracing::info!(session = %id, "auto session: the store did not take the chat: {error}");
        }
        let event = Event::from_give(&result);
        let view = match &result {
            Ok(view) => Some(Box::new(view.clone())),
            Err(error) => error.session().cloned().map(Box::new),
        };
        self.tell(super::Command::Step { id, event, view });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_move_that_did_not_happen_is_told_in_plain_words() {
        let stuck = not_moved_text(MoveTo::Cloud, Declined::Stuck);
        assert!(stuck.starts_with("This chat was not moved to the Cloud: the turn"), "{stuck}");
        let refused = not_moved_text(MoveTo::Local, Declined::Refused);
        assert!(refused.contains("your computer") && refused.contains("standing by"), "{refused}");
        for text in [stuck, refused, not_moved_text(MoveTo::Cloud, Declined::TooLarge)] {
            for word in ["lease", "epoch", "give", "wish", "auto."] {
                assert!(!text.contains(word), "{text}");
            }
        }
    }
}
