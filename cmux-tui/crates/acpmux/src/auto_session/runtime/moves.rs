//! A chat the person moves now (`_acpmux/auto_session/move`), and a chat set to run on this
//! machine only while the Cloud holds it (`_acpmux/auto_session/set` with `mode: "local"`).
//!
//! A move is the person's wish, sent to the store. The store acts on it at once for a chat
//! nobody runs; otherwise the chat's holder gives it (`give.rs`). When this laptop is that
//! holder it starts the give from the store's answer, without waiting for its next renewal.
//!
//! A chat set to this machine only is moved home first. Auto goes off for it once it is here,
//! this machine has stored a copy of its own and has taken the chat's Cloud inbox: the store
//! refuses earlier, while the Cloud has something this machine has not, and closing the chat
//! there drops what the inbox still held.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::AutoCloudError;
use cmux_auto_session::holder::{CopyState, Event, Side, State};
use cmux_auto_session::wire::{ErrorCode, MoveRefusal, MoveRequest, MoveTo, SessionView};
use serde_json::json;

use super::chats::auto;
use super::run::Loop;
use super::switch::answer;
use super::tasks::{Ctx, answered, row};
use super::{Command, Reply};
use crate::auto_session::HolderHandle;
use crate::rpc::RpcError;

/// Where a move goes, in the person's words.
fn place(to: MoveTo) -> &'static str {
    match to {
        MoveTo::Cloud => "the Cloud",
        MoveTo::Local => "this computer",
    }
}

/// A move that did not happen, as the request's error: one plain sentence, with the store's
/// code as `data.reason`.
fn refused(reason: &str, retryable: bool, text: String) -> RpcError {
    RpcError::new(-32000, text).with_data(json!({"reason": reason, "retryable": retryable}))
}

/// The chat has Auto off: there is nothing to move.
fn auto_is_off(to: MoveTo) -> RpcError {
    let text = format!(
        "This chat runs on this computer only, so it cannot be moved to {}. Set it to Auto or \
         Cloud first.",
        place(to)
    );
    refused(MoveRefusal::Off.as_str(), false, text)
}

/// Why the store did not take a move `to`, for the person.
fn move_error(error: &AutoCloudError, to: MoveTo) -> RpcError {
    let stays = "It stays where it is.";
    let (reason, why) = match (error.move_refusal(), error.code()) {
        (Some(MoveRefusal::Off), _) => return auto_is_off(to),
        (Some(MoveRefusal::NoLaptop), _) => (
            MoveRefusal::NoLaptop.as_str(),
            "this computer is not ready to take it back yet; try again in a moment".to_owned(),
        ),
        (Some(MoveRefusal::NotCopied), _) => (
            MoveRefusal::NotCopied.as_str(),
            "the Cloud does not have a copy of it yet; try again in a moment".to_owned(),
        ),
        (Some(refusal @ MoveRefusal::NoMove), _) => {
            (refusal.as_str(), "the move was called off".to_owned())
        }
        (None, Some(ErrorCode::NoMachine)) => {
            (ErrorCode::NoMachine.as_str(), "there is no Cloud machine to run it on".to_owned())
        }
        (None, Some(code)) => (code.as_str(), format!("the Cloud refused ({error})")),
        (None, None) if error.status().is_some() => {
            ("auto.refused", format!("the Cloud refused ({error})"))
        }
        (None, None) => ("auto.unreachable", "the Cloud did not answer; try again".to_owned()),
    };
    let text = format!("This chat was not moved to {}: {why}. {stays}", place(to));
    refused(reason, error.retryable(), text)
}

impl<C: AutoCloud + 'static> Loop<C> {
    /// `_acpmux/auto_session/move`: asks the store to move the chat `to`. `leave`: the chat is
    /// set to this machine only, and the move home is its first step.
    pub(super) fn move_chat(&mut self, id: &str, to: MoveTo, leave: bool, reply: Reply) {
        if self.side != Side::Laptop {
            let refusal = "a chat is moved from the person's own devices";
            return answer(Some(reply), Err(RpcError::invalid_params(refusal)));
        }
        if self.hub.auto_session(id).is_none() {
            return answer(Some(reply), Err(RpcError::not_found(format!("no session {id}"))));
        }
        if !self.chats.get(id).is_some_and(|tracked| auto(&tracked.chat)) {
            return answer(Some(reply), Err(auto_is_off(to)));
        }
        let request = match to {
            MoveTo::Cloud => MoveRequest::cloud(),
            // To this laptop, not to whichever of the person's laptops renewed last.
            MoveTo::Local => MoveRequest::laptop(self.ctx.me.clone()),
        };
        let task = self.ctx.clone().move_chat(id.to_owned(), to, leave, request, reply);
        self.ctx.start("auto-session move", task);
    }

    /// `mode: "local"`: the chat runs on this machine only. A chat that is here has Auto
    /// switched off, answered by the store. A chat the Cloud has is moved home first; the
    /// request is answered once the store took the move, and Auto goes off when the chat is
    /// here ([`Self::leave_when_home`]).
    pub(super) async fn go_local(&mut self, id: &str, reply: Reply) {
        let state = self.chats.get(id).map(|tracked| tracked.chat.state);
        match state {
            Some(State::Standby { .. }) => self.move_chat(id, MoveTo::Local, true, reply),
            // On its way in already: Auto goes off once it is here.
            Some(State::ComingHome { .. }) => {
                let view = self.chats.get(id).and_then(|tracked| tracked.view.as_ref());
                let kept = view.is_some_and(|view| view.keep_in_cloud);
                if kept {
                    // The store still keeps the chat in the Cloud, which ends "this machine
                    // only" (`chats.rs`): a move here tells it otherwise, in one write.
                    return self.move_chat(id, MoveTo::Local, true, reply);
                }
                self.want_local(id, true);
                answer(Some(reply), Ok(row(&self.hub, id)));
            }
            Some(
                State::Off
                | State::Registering
                | State::Holding { .. }
                | State::Stopped { .. }
                | State::Giving { .. }
                | State::Away
                | State::Taking { .. }
                | State::Serving { .. }
                | State::Returning { .. },
            )
            | None => self.switch(id, false, None, Some(reply)).await,
        }
    }

    /// The store answered a move. Its view is the chat's newest; a laptop that holds the chat
    /// starts the give now, and one the store just gave a parked chat to asks for it now.
    pub(super) async fn moved(
        &mut self,
        id: &str,
        (to, leave): (MoveTo, bool),
        result: Result<SessionView, AutoCloudError>,
        reply: Reply,
    ) {
        let (view, error) = match result {
            Ok(view) => (Some(view), None),
            Err(error) => (error.session().cloned(), Some(error)),
        };
        match &error {
            // What the person chose last counts: a move to the Cloud ends "this machine only".
            None => self.want_local(id, leave),
            // A move that did not happen changes nothing.
            Some(error) => {
                tracing::info!(session = %id, "auto session: the chat was not moved: {error}");
            }
        }
        let wish = view.as_ref().and_then(|view| view.moving.as_ref());
        let wish = wish.map(|wish| (wish.to, wish.at));
        let mine = view.as_ref().is_some_and(|view| view.holder == self.ctx.me);
        if let (Some(tracked), Some(view)) = (self.chats.get_mut(id), view) {
            tracked.note_view(view);
        }
        self.sync(id);
        if error.is_none() {
            let state = self.chats.get(id).map(|tracked| tracked.chat.state);
            match (state, wish) {
                (Some(State::Holding { .. }), Some((to, at))) => {
                    self.step(id, Event::Wished { to, at: Some(at) }).await;
                }
                (Some(State::Standby { .. }), _) if mine => self.step(id, Event::Wake).await,
                _ => {}
            }
        }
        let result = match &error {
            None => Ok(row(&self.hub, id)),
            Some(error) => Err(move_error(error, to)),
        };
        answer(Some(reply), result);
    }

    /// Notes in the chat's record whether it is set to this machine only.
    fn want_local(&self, id: &str, wanted: bool) {
        let Some(session) = self.hub.auto_session(id) else { return };
        self.hub.update_auto_record(&session, |old| {
            old.map(|mut record| {
                record.local_wanted = wanted;
                record
            })
        });
    }

    /// A chat set to this machine only, once it is home with a copy of its own in the store and
    /// nothing of the Cloud's is still owed to this machine: Auto goes off.
    ///
    /// Closing a chat in the store marks its whole inbox as taken, so a prompt sent while the
    /// chat was on its way home must be this machine's first: the chat's lane is empty and
    /// idle (no drain waits or runs), and the store's last view has no message this machine
    /// has not taken. The store also refuses while the chat still owes it a copy.
    ///
    /// Asked whenever one of those may have become true: a copy ended, the lane finished, or a
    /// view came from the store (`run.rs`). It reads the record only for a chat that is home.
    pub(super) async fn leave_when_home(&mut self, id: &str) {
        let Some(tracked) = self.chats.get(id) else { return };
        let home = matches!(tracked.chat.state, State::Holding { .. })
            && tracked.chat.copy == CopyState::Stored;
        let idle = tracked.lane.is_empty() && !tracked.lane_busy;
        let taken = tracked.view.as_ref().is_some_and(|view| !view.inbox_pending());
        if !home || !idle || !taken || tracked.leaving {
            return;
        }
        let wanted = self
            .hub
            .auto_session(id)
            .and_then(|session| self.hub.auto_record(&session))
            .is_some_and(|record| record.local_wanted);
        if !wanted {
            return;
        }
        // One ask at a time: the store's answer clears it (`switch.rs` `closed`).
        if let Some(tracked) = self.chats.get_mut(id) {
            tracked.leaving = true;
        }
        self.step(id, Event::AutoOff).await;
    }
}

impl HolderHandle {
    /// What a request to run a chat in the Cloud answers when the Cloud has not said yet that
    /// the chat is an Auto chat (its registration got no answer): the words of a move the
    /// Cloud did not answer, which can be asked again.
    pub(crate) fn cloud_did_not_answer() -> RpcError {
        let silent = AutoCloudError::transport("the Cloud did not answer in time");
        move_error(&silent, MoveTo::Cloud)
    }
}

impl<C: AutoCloud + 'static> Ctx<C> {
    /// `POST /:id/move`. The loop answers `reply` once the row follows the store's answer.
    async fn move_chat(
        self,
        id: String,
        to: MoveTo,
        leave: bool,
        request: MoveRequest,
        reply: Reply,
    ) {
        let result = answered(self.cloud.move_(&id, &request)).await;
        self.tell(Command::Moved { id, to, leave, result, reply });
    }
}

#[cfg(test)]
#[path = "moves_tests.rs"]
mod tests;
