//! Auto switched on or off for a chat (`_acpmux/auto_session/set`), whether it stays in the
//! Cloud, and a prompt for a chat this machine may not run now.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::AutoCloudError;
use cmux_auto_session::holder::{Chat, Event, Side, State};
use cmux_auto_session::wire::{ErrorCode, InboxPost, SessionView};
use serde_json::{Value, json};

use super::Reply;
use super::chats::{Opening, Tracked, auto};
use super::run::Loop;
use super::tasks::{cloud_error, row};
use crate::auto_session::record::AutoRecord;
use crate::rpc::RpcError;

/// The longest id the store takes for an inbox message.
const MESSAGE_ID_MAX: usize = 128;

/// The inbox message's id for a prompt: the prompt's own id, so the same prompt sent again is
/// the same message, or a new one when the prompt has none the store takes.
pub(super) fn message_id(prompt_id: Option<&str>) -> String {
    let taken = |id: &str| {
        !id.is_empty()
            && id.len() <= MESSAGE_ID_MAX
            && id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
    };
    match prompt_id {
        Some(id) if taken(id) => id.to_owned(),
        Some(_) | None => uuid::Uuid::now_v7().to_string(),
    }
}

pub(super) fn answer(reply: Option<Reply>, result: Result<Value, RpcError>) {
    if let Some(reply) = reply {
        // Whoever asked may have gone.
        let _ = reply.send(result);
    }
}

/// What a prompt gets while the chat waits to hear from the store.
fn waits_for_network() -> RpcError {
    RpcError::new(
        -32000,
        "auto.offline: this chat waits for the Cloud before it goes on; send again once this \
         machine is back online",
    )
    .with_data(json!({"reason": "auto.offline", "retryable": true}))
}

fn not_here() -> RpcError {
    RpcError::new(-32000, "auto.away: this chat is not running on this machine now")
        .with_data(json!({"reason": "auto.away", "retryable": true}))
}

/// The store has no such open chat: Auto is off for it.
fn gone(error: &AutoCloudError) -> bool {
    error.code() == Some(ErrorCode::Closed) || error.status() == Some(404)
}

/// The record a chat gets when Auto is switched on for it: nothing of an earlier time in the
/// Cloud counts, but changes kept aside stay.
fn fresh_record(old: Option<AutoRecord>, keep: Option<bool>) -> AutoRecord {
    let mut record = AutoRecord { leftover: old.and_then(|old| old.leftover), ..AutoRecord::on() };
    record.here = true;
    record.keep_in_cloud = keep.unwrap_or(false);
    record
}

impl<C: AutoCloud + 'static> Loop<C> {
    /// Auto on or off for a chat. The chat goes on running here while the store is told, and
    /// the request is answered from the store's answer: on, once the registration was answered
    /// (`register.rs`); off, once the store closed the chat, or refused.
    pub(super) async fn switch(
        &mut self,
        id: &str,
        on: bool,
        keep: Option<bool>,
        reply: Option<Reply>,
    ) {
        if self.side != Side::Laptop {
            let refusal = "Auto mode is switched from the person's own devices";
            return answer(reply, Err(RpcError::invalid_params(refusal)));
        }
        let Some(session) = self.hub.auto_session(id) else {
            return answer(reply, Err(RpcError::not_found(format!("no session {id}"))));
        };
        let is_on = self.chats.get(id).is_some_and(|tracked| auto(&tracked.chat));
        match (on, is_on) {
            (true, false) => {
                self.hub.update_auto_record(&session, |old| Some(fresh_record(old, keep)));
                let now = self.now();
                let mut tracked = Tracked::new(Chat::new(Side::Laptop, now));
                // Whoever still waits on the chat as it was waits on it as it is now.
                if let Some(old) = self.chats.remove(id) {
                    tracked.opening = old.opening;
                    tracked.closing = old.closing;
                }
                if let Some(reply) = reply {
                    tracked.opening.push(Opening { reply, keep });
                }
                self.chats.insert(id.to_owned(), tracked);
                self.step(id, Event::AutoOn).await;
                self.read_work(id, None);
            }
            (true, true) => {
                // Auto asked for again: the chat is no longer set to this machine only.
                self.hub.update_auto_record(&session, |old| {
                    old.map(|record| AutoRecord { local_wanted: false, ..record })
                });
                self.keep(id, keep, reply);
            }
            (false, false) => answer(reply, Ok(row(&self.hub, id))),
            (false, true) => {
                if let (Some(tracked), Some(reply)) = (self.chats.get_mut(id), reply) {
                    tracked.closing.push(reply);
                }
                self.step(id, Event::AutoOff).await;
            }
        }
    }

    /// Auto on for a chat that has it on: the request may say whether the chat stays in the
    /// Cloud when this machine returns. The store is asked first. Nothing changes here until it
    /// answered, and its answer is the request's ([`Self::kept`]).
    fn keep(&mut self, id: &str, keep: Option<bool>, reply: Option<Reply>) {
        let Some(tracked) = self.chats.get_mut(id) else {
            return answer(reply, Ok(row(&self.hub, id)));
        };
        if matches!(tracked.chat.state, State::Registering) {
            // The store does not have the chat yet. The next registration says what the record
            // says, and a registration's answer answers this request (`register.rs`).
            if let Some(reply) = reply {
                tracked.opening.push(Opening { reply, keep });
            }
            if let (Some(keep), Some(session)) = (keep, self.hub.auto_session(id)) {
                self.hub.update_auto_record(&session, |old| {
                    old.map(|record| AutoRecord { keep_in_cloud: keep, ..record })
                });
            }
            return;
        }
        let known = tracked.view.as_ref().map(|view| view.keep_in_cloud);
        match keep {
            Some(keep) if known != Some(keep) => self.ask_keep(id, keep, reply),
            Some(_) | None => answer(reply, Ok(row(&self.hub, id))),
        }
    }

    /// Asks the store to keep the chat in the Cloud, or to stop keeping it. `reply` is answered
    /// with what the store says.
    pub(super) fn ask_keep(&self, id: &str, keep: bool, reply: Option<Reply>) {
        self.ctx.start("auto-session keep", self.ctx.clone().keep(id.to_owned(), keep, reply));
    }

    /// The store answered whether the chat stays in the Cloud. The row and the record follow
    /// the store: its view on a yes, the view a refusal carried, and otherwise what they were.
    /// Whoever asked gets the row, or the store's refusal.
    pub(super) fn kept(
        &mut self,
        id: &str,
        result: Result<SessionView, AutoCloudError>,
        reply: Option<Reply>,
    ) {
        let (view, refused) = match result {
            Ok(view) => (Some(view), None),
            Err(error) => {
                tracing::warn!(session = %id, "auto session: keep in the Cloud not set: {error}");
                (error.session().cloned(), Some(error))
            }
        };
        if let (Some(tracked), Some(view)) = (self.chats.get_mut(id), view) {
            tracked.note_view(view);
        }
        self.sync(id);
        let result = match &refused {
            None => Ok(row(&self.hub, id)),
            Some(error) => Err(cloud_error(error)),
        };
        answer(reply, result);
    }

    /// The store answered Auto off. A refusal (`auto.held_in_cloud`: the Cloud has something
    /// no laptop has) leaves the chat an Auto chat, and whoever asked hears why.
    pub(super) async fn closed(&mut self, id: &str, result: Result<SessionView, AutoCloudError>) {
        let waiting = match self.chats.get_mut(id) {
            Some(tracked) => {
                // A chat set to this machine only may ask again (`moves.rs`).
                tracked.leaving = false;
                std::mem::take(&mut tracked.closing)
            }
            None => Vec::new(),
        };
        // The chat's epoch in the store's answer tells the core whether a stopped tree is
        // still the whole chat; an answer with no chat in it names none (0).
        let (closed_at, refused) = match result {
            Ok(view) => (Some(view.epoch), None),
            Err(error) if gone(&error) => {
                (Some(error.session().map_or(0, |session| session.epoch)), None)
            }
            Err(error) => (None, Some(error)),
        };
        if let Some(epoch) = closed_at {
            self.step(id, Event::Closed { epoch }).await;
        }
        for reply in waiting {
            let result = match &refused {
                None => Ok(row(&self.hub, id)),
                Some(error) => Err(cloud_error(error)),
            };
            answer(Some(reply), result);
        }
        self.forget_spent(id);
    }

    /// A prompt for a chat this machine may not run now. Another holder's chat takes it through
    /// its Cloud inbox; a chat stopped here waits for the store first.
    pub(super) fn away(&mut self, id: &str, post: InboxPost, reply: Reply) {
        let state = self.chats.get(id).map(|tracked| tracked.chat.state);
        // A chat in the middle of a give takes it through the inbox too: it runs once, where
        // the chat lands, or here when the chat stays (the drain of a chat that may run again).
        let standby = match state {
            Some(State::Standby { .. } | State::ComingHome { .. }) => true,
            Some(State::Giving { .. } | State::Returning { .. }) => false,
            Some(State::Stopped { .. }) => return answer(Some(reply), Err(waits_for_network())),
            Some(
                State::Off
                | State::Registering
                | State::Holding { .. }
                | State::Away
                | State::Taking { .. }
                | State::Serving { .. },
            )
            | None => return answer(Some(reply), Err(not_here())),
        };
        let task = self.ctx.clone().post(id.to_owned(), post, reply, standby);
        self.ctx.start("auto-session inbox post", task);
    }
}

#[cfg(test)]
#[path = "switch_tests.rs"]
mod tests;
