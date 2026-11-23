//! Auto switched on or off for a chat (`_acpmux/auto_session/set`), whether it stays in the
//! Cloud, and a prompt for a chat this machine may not run now.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::AutoCloudError;
use cmux_auto_session::holder::{Chat, Event, Side, State};
use cmux_auto_session::wire::{ErrorCode, InboxPost, SessionView};
use serde_json::{Value, json};

use super::Reply;
use super::chats::{Tracked, auto};
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

fn answer(reply: Option<Reply>, result: Result<Value, RpcError>) {
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
    /// Auto on or off for a chat. On answers at once: the chat goes on running here while the
    /// store is told. Off answers once the store closed the chat, or refused.
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
                self.chats.insert(id.to_owned(), Tracked::new(Chat::new(Side::Laptop, now)));
                self.step(id, Event::AutoOn).await;
                self.read_work(id, None);
                answer(reply, Ok(row(&self.hub, id)));
            }
            (true, true) => {
                if let Some(keep) = keep {
                    self.keep(id, keep);
                }
                answer(reply, Ok(row(&self.hub, id)));
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

    /// Whether the chat stays in the Cloud when this machine returns: the row says so at once,
    /// and the store's answer settles it.
    fn keep(&mut self, id: &str, keep: bool) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        let known = tracked.view.as_ref().map(|view| view.keep_in_cloud);
        if known == Some(keep) {
            return;
        }
        if let Some(view) = tracked.view.as_mut() {
            view.keep_in_cloud = keep;
        }
        if let Some(session) = self.hub.auto_session(id) {
            self.hub.update_auto_record(&session, |old| {
                old.map(|record| AutoRecord { keep_in_cloud: keep, ..record })
            });
        }
        // A chat the store does not have yet says it when it registers.
        if !matches!(tracked.chat.state, State::Registering) {
            self.ctx.start("auto-session keep", self.ctx.clone().keep(id.to_owned(), keep));
        }
        self.sync(id);
    }

    /// The store answered whether the chat stays in the Cloud.
    pub(super) fn kept(&mut self, id: &str, result: Result<SessionView, AutoCloudError>) {
        match result {
            Ok(view) => {
                if let Some(tracked) = self.chats.get_mut(id) {
                    tracked.note_view(view);
                }
                self.sync(id);
            }
            Err(error) => {
                tracing::warn!(session = %id, "auto session: keep in the Cloud not set: {error}");
            }
        }
    }

    /// The store answered Auto off. A refusal (`auto.held_in_cloud`: the Cloud has something
    /// no laptop has) leaves the chat an Auto chat, and whoever asked hears why.
    pub(super) async fn closed(&mut self, id: &str, result: Result<SessionView, AutoCloudError>) {
        let waiting = match self.chats.get_mut(id) {
            Some(tracked) => std::mem::take(&mut tracked.closing),
            None => Vec::new(),
        };
        let refused = match result {
            Ok(_) => None,
            Err(error) if gone(&error) => None,
            Err(error) => Some(error),
        };
        if refused.is_none() {
            self.step(id, Event::Closed).await;
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
        match state {
            Some(State::Standby { .. } | State::ComingHome { .. }) => {
                let task = self.ctx.clone().post(id.to_owned(), post, reply);
                self.ctx.start("auto-session inbox post", task);
            }
            Some(State::Stopped { .. }) => answer(Some(reply), Err(waits_for_network())),
            Some(
                State::Off
                | State::Registering
                | State::Holding { .. }
                | State::Away
                | State::Taking { .. }
                | State::Serving { .. },
            )
            | None => answer(Some(reply), Err(not_here())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_prompt_id_the_store_takes_is_the_message_id() {
        assert_eq!(message_id(Some("p-1_a.b:c")), "p-1_a.b:c");
        let minted = message_id(Some("has space"));
        assert_ne!(minted, "has space");
        assert!(minted.len() <= MESSAGE_ID_MAX);
        assert_ne!(message_id(None), message_id(None));
    }

    #[test]
    fn switching_on_again_starts_from_nothing_but_keeps_the_leftover() {
        let mut old = AutoRecord::on();
        old.auto = false;
        old.epoch = 9;
        old.snapshot = 4;
        old.anchor = Some("tree".into());
        old.leftover = Some(crate::auto_session::record::Leftover {
            files: vec!["a".into()],
            at: 1,
            path: "/x/p".into(),
            top: "/x".into(),
        });
        let record = fresh_record(Some(old), Some(true));
        assert!(record.auto && record.here && record.keep_in_cloud);
        assert_eq!((record.epoch, record.snapshot, record.anchor.clone()), (0, 0, None));
        assert!(record.leftover.is_some());
    }
}
