//! The person's Auto chats this laptop does not have: one started from the phone with the
//! laptop off, or one another of their machines put into the Cloud.
//!
//! The loop asks the store for the owner's open chats at three moments only: when it starts,
//! when the system wakes and when the network changes. For each chat it has no session of, it
//! stands by (a standby renewal, then one a period like any standby). When the store answers
//! "holder", the state machine imports the chat as it does any handback, and the importer
//! makes the session and its folder. Until then the chat has no session here, and so no row.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::AutoCloudError;
use cmux_auto_session::holder::{Chat, Side};
use cmux_auto_session::wire::SessionView;

use super::Command;
use super::chats::Tracked;
use super::run::Loop;
use super::tasks::Ctx;

/// The most pages one look reads.
const PAGES_MAX: usize = 32;

/// Whether the owner's chats are being read.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum Look {
    #[default]
    Idle,
    /// A read is on its way. `again`: one of the three moments came meanwhile, so read once
    /// more when it ends.
    Reading { again: bool },
}

impl<C: AutoCloud + 'static> Ctx<C> {
    /// Reads the owner's open chats, every page, and tells the loop.
    pub(super) async fn list(self) {
        let result = self.pages().await;
        self.tell(Command::Listed { result });
    }

    async fn pages(&self) -> Result<Vec<SessionView>, AutoCloudError> {
        let mut found = Vec::new();
        let mut cursor: Option<String> = None;
        for _page in 0..PAGES_MAX {
            let page = self.cloud.list(None, cursor.as_deref()).await?;
            found.extend(page.sessions);
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        Ok(found)
    }
}

impl<C: AutoCloud + 'static> Loop<C> {
    /// Asks the store for the owner's chats, on a laptop. One read runs at a time.
    pub(super) fn look(&mut self) {
        if self.side != Side::Laptop {
            return;
        }
        match self.look {
            Look::Idle => {
                self.look = Look::Reading { again: false };
                self.ctx.start("auto-session list", self.ctx.clone().list());
            }
            Look::Reading { .. } => self.look = Look::Reading { again: true },
        }
    }

    /// The owner's chats were read: this laptop stands by for each one it does not have.
    pub(super) async fn listed(&mut self, result: Result<Vec<SessionView>, AutoCloudError>) {
        let again = self.look == Look::Reading { again: true };
        self.look = Look::Idle;
        match result {
            Ok(views) => {
                for view in views {
                    self.stand_by(view).await;
                }
            }
            // The next of the three moments asks again.
            Err(error) => tracing::debug!("auto session: the owner's chats were not read: {error}"),
        }
        if again {
            self.look();
        }
    }

    /// Stands by for a chat of the owner's that is not on this laptop. That includes one the
    /// store says this laptop holds (the daemon stopped while it brought the chat in): with no
    /// session here nothing runs it, and the store answers its standby renewal "holder", so it
    /// is brought in now.
    async fn stand_by(&mut self, view: SessionView) {
        if !view.auto {
            return;
        }
        let id = view.id.clone();
        if self.chats.contains_key(&id) || self.hub.auto_session(&id).is_some() {
            return;
        }
        let now = self.now();
        let before = Chat::new(Side::Laptop, now);
        let (chat, effects) = Chat::standby(view.epoch, now);
        let mut tracked = Tracked::new(chat);
        tracked.absent = true;
        tracked.note_view(view);
        self.chats.insert(id.clone(), tracked);
        self.settle(&id, before, effects).await;
    }
}
