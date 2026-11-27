//! The store's answer to Auto on.
//!
//! Switching Auto on registers the chat with the store (`PUT /:id`). The chat goes on running
//! here meanwhile, and whoever switched it on waits for the registration's answer
//! (`Tracked::opening`), so the pane says what the store said:
//!
//! - The store took the chat: the row.
//! - The store refused: its refusal. One that would be the same next time (anything but a 408,
//!   425, 429 or 5xx) also ends the tries: Auto is off for the chat again, as its row then says.
//! - No answer in the time a registration is given, which is under one renewal period: the row
//!   as it is, Auto on and not in the Cloud yet. The loop registers again every period.
//!
//! How an answer moves the chat's state is the state machine's (`cmux-auto-session`); this
//! only passes the answer on and decides what the waiting requests hear.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::AutoCloudError;
use cmux_auto_session::holder::{Event, State};
use cmux_auto_session::wire::SessionView;

use super::chats::Opening;
use super::run::Loop;
use super::switch::answer;
use super::tasks::{cloud_error, row};

/// The store answered, and would answer the same registration the same way again.
fn refusal(error: &AutoCloudError) -> bool {
    matches!(error, AutoCloudError::Http { .. }) && !error.retryable()
}

impl<C: AutoCloud + 'static> Loop<C> {
    /// The registration numbered `request` ended with `result`.
    pub(super) async fn registered(
        &mut self,
        id: &str,
        request: u64,
        result: Result<SessionView, AutoCloudError>,
    ) {
        // Taken before the state moves: a chat that goes off below answers nobody twice.
        let waiting = match self.chats.get_mut(id) {
            Some(tracked) => std::mem::take(&mut tracked.opening),
            None => Vec::new(),
        };
        let view = match &result {
            Ok(view) => Some(view.clone()),
            Err(error) => error.session().cloned(),
        };
        if let (Some(tracked), Some(view)) = (self.chats.get_mut(id), view) {
            tracked.note_view(view);
        }
        let event = Event::from_registration(request, &self.ctx.me, &result);
        self.step(id, event).await;

        let refused = result.as_ref().err().filter(|error| refusal(error));
        let registering = self
            .chats
            .get(id)
            .is_some_and(|tracked| matches!(tracked.chat.state, State::Registering));
        if refused.is_some() && registering {
            // The state machine would send the same registration every period, for nothing.
            self.step(id, Event::AutoOff).await;
        }
        // Whether the chat stays in the Cloud, as the store has it now.
        let kept = result.as_ref().ok().filter(|view| view.auto).map(|view| view.keep_in_cloud);
        for Opening { reply, keep } in waiting {
            match (refused, kept, keep) {
                (Some(error), _, _) => answer(Some(reply), Err(cloud_error(error))),
                // The registration that was answered said otherwise: ask now, and answer then.
                (None, Some(kept), Some(keep)) if kept != keep => {
                    self.ask_keep(id, keep, Some(reply));
                }
                (None, _, _) => answer(Some(reply), Ok(row(&self.hub, id))),
            }
        }
        self.forget_spent(id);
    }
}
