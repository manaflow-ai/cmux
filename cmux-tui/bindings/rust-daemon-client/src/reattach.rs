//! Reconnect after an attachment ended: the caller owns it (see
//! [`crate::attach`]); this module has the two pieces every caller needs.
//!
//! - [`MirrorWatch`]: the daemon generation and terminal ids of the caller's
//!   control mirror, shared with attachment threads. Feed it from the
//!   [`crate::DaemonClient`] callback with [`MirrorWatch::observe`].
//! - [`reattach`]: opens a new attachment as [`AttachEnd::reattach`] says.
//!   After a daemon shutdown it first waits until the mirror resolves the
//!   terminal in a new generation (no polling: a condition variable the
//!   mirror callback signals).
//!
//! Both block, so run them on an attachment or worker thread, never on the
//! UI thread. A reattach replays into a FRESH surface: the new sink's first
//! call is `replay`.

use crate::attach::{
    AttachEnd, AttachError, AttachRequest, Reattach, TerminalAttacher, TerminalAttachment,
    TerminalByteSink,
};
use crate::mirror::Mirror;
use cmux::TerminalId;
use std::collections::BTreeSet;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// The control mirror's generation and terminals, for attachment threads.
/// Cheap to clone (shared).
#[derive(Clone, Debug, Default)]
pub struct MirrorWatch {
    shared: Arc<(Mutex<Seen>, Condvar)>,
}

#[derive(Debug, Default)]
struct Seen {
    generation: Option<String>,
    terminals: BTreeSet<TerminalId>,
    closed: bool,
}

/// How waiting for a new generation ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GenerationWait {
    /// The mirror has a new generation that still has the terminal.
    Resolved(String),
    /// The new generation does not have the terminal.
    Gone,
    TimedOut,
    /// [`MirrorWatch::close`] was called.
    Closed,
}

impl MirrorWatch {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, Seen> {
        self.shared.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Records the mirror (call on `Reset` and `Delta`). Copies the terminal
    /// ids, so keep the call in the callback; it is linear in terminals.
    pub fn observe(&self, mirror: &Mirror) {
        let generation = mirror.cursor.as_ref().map(|c| c.generation.clone());
        self.update(generation, mirror.terminals.keys().cloned());
    }

    /// Records a generation and its terminals directly.
    pub fn update(
        &self,
        generation: Option<String>,
        terminals: impl IntoIterator<Item = TerminalId>,
    ) {
        let mut seen = self.lock();
        seen.generation = generation;
        seen.terminals = terminals.into_iter().collect();
        drop(seen);
        self.shared.1.notify_all();
    }

    /// Wakes every waiter for good (the app is shutting down).
    pub fn close(&self) {
        self.lock().closed = true;
        self.shared.1.notify_all();
    }

    /// The current generation, when it has `terminal`.
    pub fn generation_of(&self, terminal: &TerminalId) -> Option<String> {
        let seen = self.lock();
        seen.terminals.contains(terminal).then(|| seen.generation.clone()).flatten()
    }

    /// Blocks until the mirror reports a generation other than `stale`, then
    /// says whether it still has `terminal`.
    pub fn wait_for_new_generation(
        &self,
        terminal: &TerminalId,
        stale: &str,
        timeout: Duration,
    ) -> GenerationWait {
        self.wait(timeout, |seen| {
            let generation = seen.generation.as_deref().filter(|g| *g != stale)?;
            Some(if seen.terminals.contains(terminal) {
                GenerationWait::Resolved(generation.to_string())
            } else {
                GenerationWait::Gone
            })
        })
    }

    /// Blocks until the mirror has `terminal` (a terminal created through
    /// the SDK reaches the mirror shortly after the create reply) and
    /// returns its generation. Never `Gone`: absence may mean "not yet".
    pub fn wait_for_terminal(&self, terminal: &TerminalId, timeout: Duration) -> GenerationWait {
        self.wait(timeout, |seen| {
            let generation = seen.generation.as_ref().filter(|_| seen.terminals.contains(terminal));
            generation.map(|g| GenerationWait::Resolved(g.clone()))
        })
    }

    /// Waits on the condition variable until `done` decides, the deadline
    /// passes, or the watch closes.
    fn wait(
        &self,
        timeout: Duration,
        mut done: impl FnMut(&Seen) -> Option<GenerationWait>,
    ) -> GenerationWait {
        let deadline = Instant::now() + timeout;
        let mut seen = self.lock();
        loop {
            if seen.closed {
                return GenerationWait::Closed;
            }
            if let Some(outcome) = done(&seen) {
                return outcome;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return GenerationWait::TimedOut;
            }
            seen = self
                .shared
                .1
                .wait_timeout(seen, left)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
    }
}

/// Opens a new attachment for `request.terminal` after `end`:
/// - [`Reattach::Never`]: returns `end`.
/// - [`Reattach::Now`]: attaches with the watch's current generation for the
///   terminal (or `request.generation` without a watch or before it knows).
/// - [`Reattach::AfterGenerationResolves`]: waits up to `wait` until `watch`
///   has a generation other than `request.generation`, then attaches with it.
///
/// A refused attach (the identity fence or an unknown terminal) returns
/// [`AttachEnd::TerminalGone`]; other failures [`AttachEnd::Failed`].
pub fn reattach(
    attacher: &dyn TerminalAttacher,
    end: &AttachEnd,
    mut request: AttachRequest,
    watch: Option<&MirrorWatch>,
    wait: Duration,
    sink: Box<dyn TerminalByteSink>,
) -> Result<Box<dyn TerminalAttachment>, AttachEnd> {
    match end.reattach() {
        Reattach::Never => return Err(end.clone()),
        Reattach::Now => {
            if let Some(generation) = watch.and_then(|w| w.generation_of(&request.terminal)) {
                request.generation = generation;
            }
        }
        Reattach::AfterGenerationResolves => {
            let Some(watch) = watch else {
                return Err(AttachEnd::Failed(
                    "the daemon restarted and no mirror resolves the terminal".into(),
                ));
            };
            match watch.wait_for_new_generation(&request.terminal, &request.generation, wait) {
                GenerationWait::Resolved(generation) => request.generation = generation,
                GenerationWait::Gone => {
                    return Err(AttachEnd::TerminalGone(
                        "the restarted daemon has no such terminal".into(),
                    ));
                }
                GenerationWait::TimedOut => {
                    return Err(AttachEnd::Failed(format!(
                        "no new daemon generation within {wait:?}"
                    )));
                }
                GenerationWait::Closed => return Err(AttachEnd::Released),
            }
        }
    }
    attacher.attach(request, sink).map_err(|error| match error {
        AttachError::Rejected(message) => AttachEnd::TerminalGone(message),
        other => AttachEnd::Failed(other.to_string()),
    })
}
