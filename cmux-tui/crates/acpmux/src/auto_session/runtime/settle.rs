//! A chat's work that ends with no record in its log.
//!
//! A turn that just ended still counts as work until the hub has settled whether the turn is
//! continued (`hub/auto_resume.rs`), a moment after the turn's result is in the log. The loop
//! reads the chat's work at that result, so it reads "at work", and no later record says the
//! chat came to rest. The hub's watch does ([`Hub::auto_work_settles`]): one task per chat
//! waits on it, and the loop reads the work again when it changes. So the store hears "nothing
//! left to run" at the turn's end and not a renewal period later, which is when a Cloud
//! machine hands the chat back and what a laptop's lapsed lease is decided on.
//!
//! [`Hub::auto_work_settles`]: crate::hub::Hub::auto_work_settles

use cmux_auto_session::AutoCloud;
use tokio::sync::watch;

use super::Command;
use super::run::Loop;
use super::tasks::Ctx;

impl<C: AutoCloud + 'static> Ctx<C> {
    /// Waits for the chat's work to settle, then tells the loop.
    pub(super) async fn settled(self, id: String, mut settles: watch::Receiver<u64>) {
        // An error is the chat's session gone from this daemon: the loop reads all the same.
        let _ = settles.changed().await;
        self.tell(Command::Settled { id });
    }
}

impl<C: AutoCloud + 'static> Loop<C> {
    /// A read said the chat is at work, with the watch taken before it: one task waits on it.
    pub(super) fn watch_settle(&mut self, id: &str, settles: Option<watch::Receiver<u64>>) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        let Some(settles) = settles.filter(|_| !tracked.settling) else { return };
        tracked.settling = true;
        let task = self.ctx.clone().settled(id.to_owned(), settles);
        self.ctx.start("auto-session settle", task);
    }

    /// The chat's work settled: read it again.
    pub(super) fn settled(&mut self, id: &str) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        tracked.settling = false;
        if tracked.chat.may_run() {
            self.read_work(id, None);
        }
    }
}
