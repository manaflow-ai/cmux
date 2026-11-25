//! The task that keeps one chat's projection: it waits on the store's version, reads the new
//! events page by page, and ends when the loop drops the projection.

use std::future::Future;
use std::sync::Arc;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::{RENEW_MS, WAIT_MAX_MS};
use tokio::sync::watch;

use super::{Projections, Status, projected};
use crate::auto_session::runtime::run::Loop;
use crate::auto_session::runtime::tasks::Ctx;

/// Ends a reader once its projection is dropped.
pub(crate) struct Stop(pub(super) watch::Receiver<()>);

impl Stop {
    /// `work`, or None once the projection is dropped.
    async fn or_stop<T>(&mut self, work: impl Future<Output = T>) -> Option<T> {
        tokio::select! {
            // The sender lives in the projection: dropping it ends the wait with an error.
            _ = self.0.changed() => None,
            done = work => Some(done),
        }
    }
}

/// The most pages one catch-up reads before it waits again.
const PAGES_MAX: usize = 64;

impl<C: AutoCloud + 'static> Ctx<C> {
    /// Keeps chat `id`'s projection of generation `generation` until it is dropped.
    async fn project(self, id: String, generation: u64, mut stop: Stop, all: Arc<Projections>) {
        let mut version = 0;
        loop {
            let wait = self.cloud.wait(&id, version, WAIT_MAX_MS);
            let Some(answer) = stop.or_stop(wait).await else { return };
            let ok = match answer {
                Ok(view) => {
                    version = view.version;
                    let now = self.clock.now_ms();
                    let Some(next) = all.with(&id, generation, |b| b.observe(&view, now)) else {
                        return;
                    };
                    self.catch_up(&id, generation, next.verify, &mut stop, &all).await
                }
                Err(error) => Err(error.to_string()),
            };
            match ok {
                Ok(true) => {}
                Ok(false) => return,
                Err(error) => {
                    if all.with(&id, generation, |b| b.failed(error)).is_none() {
                        return;
                    }
                    // Asked again a renewal later, as the loop asks the store.
                    let again = self.clock.wait_until(self.clock.now_ms() + RENEW_MS);
                    if stop.or_stop(again).await.is_none() {
                        return;
                    }
                }
            }
        }
    }

    /// Reads what the store has past the kept events. Ok(false): the projection is gone.
    async fn catch_up(
        &self,
        id: &str,
        generation: u64,
        verify: Option<u64>,
        stop: &mut Stop,
        all: &Projections,
    ) -> Result<bool, String> {
        if let Some(seq) = verify {
            let read = self.cloud.events(id, seq.saturating_sub(1), Some(1));
            let Some(page) = stop.or_stop(read).await else { return Ok(false) };
            let page = page.map_err(|error| error.to_string())?;
            if all.with(id, generation, |b| b.verify(&page)).is_none() {
                return Ok(false);
            }
        }
        for _page in 0..PAGES_MAX {
            let Some(after) = all.with(id, generation, |b| (!b.caught_up()).then_some(b.have))
            else {
                return Ok(false);
            };
            let Some(after) = after else { break };
            let read = self.cloud.events(id, after, None);
            let Some(page) = stop.or_stop(read).await else { return Ok(false) };
            let page = page.map_err(|error| error.to_string())?;
            let empty = page.events.is_empty();
            let Some(whole) = all.with(id, generation, |b| b.take(page)) else {
                return Ok(false);
            };
            if !whole || empty {
                // A gap or a page with nothing: the next answer reads again.
                break;
            }
        }
        let caught_up = all.with(id, generation, |b| {
            b.status = if b.caught_up() { Status::Live } else { Status::Reconnecting };
        });
        Ok(caught_up.is_some())
    }
}

impl<C: AutoCloud + 'static> Loop<C> {
    /// Starts or drops chat `id`'s projection, as where the chat runs says. Called after every
    /// step of the chat.
    pub(in crate::auto_session::runtime) fn project(&mut self, id: &str) {
        let wanted = self.chats.get(id).is_some_and(|tracked| projected(&tracked.chat))
            && self.hub.auto_session(id).is_some();
        if !wanted {
            self.projections.close(id);
            return;
        }
        let Some((generation, stop)) = self.projections.open(id, self.now()) else { return };
        let task =
            self.ctx.clone().project(id.to_owned(), generation, stop, self.projections.clone());
        self.ctx.start("auto-session projection", task);
    }
}
