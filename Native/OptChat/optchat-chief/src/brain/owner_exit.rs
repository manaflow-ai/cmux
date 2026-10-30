//! The brain host stops by the stop rule every app helper follows
//! (`cmux-owner-liveness`; principled audit lagQuitHelpers, 2026-10-29,
//! which replaced cp/quit-chief-idle's `owner_gone_at` latch and its 30 s
//! link hold):
//!
//! > the host exits when it has no live owner app and no live work (the
//! > host has no clients of its own: it is a client of its owner daemon).
//!
//! The owner app is a level ([`OwnerProbe`], `owner_app.rs`): it is read at
//! every input and timer, and its kernel watch sends
//! [`super::Input::OwnerChanged`] when it changes. A host no app named
//! (`cmux chief`, the always-on brain) stays, as before.
//!
//! Live work keeps the host (Keep Sessions Running keeps the Chief
//! working): a turn that runs or waits for the compactor, a queued prompt,
//! a steer on its way, a cut turn that runs again, an adopted turn, a
//! permission request nobody answered yet, a subagent or a child session at
//! work, a wake the Chief set with `sleep`, and a conversation not yet read
//! since the host started (a host started after the quit, as another Chief a
//! message woke, reads that message first; the first link `Up` or a failed
//! connect ends this, with no timer). The brain stops at the first look
//! that finds none. Before it stops it sends what its outbox holds when its
//! link is up, and saves its state: an outbox entry it could not send and a
//! person's message it has not read stay on disk (the outbox in the memory
//! database, the message in the owner daemon's conversation), and the next
//! host sends and reads them. No hold decides what is delivered.

use std::sync::Arc;

use cmux_chief::acp::SessionStatus;
use cmux_owner_liveness::{Keeps, OwnerState};

use super::Brain;

/// The brain's stop once its app is gone and nothing keeps it.
pub const OWNER_APP_EXITED: &str = "the app quit and the Chief is idle";

/// Reads the owner app now (`owner_app::probe`; tests inject their own).
pub type OwnerProbe = Arc<dyn Fn() -> OwnerState + Send + Sync>;

impl Brain {
    /// The owner app this host serves, read through `probe` from now on.
    pub fn set_owner(&mut self, probe: OwnerProbe) {
        self.owner = Some(probe);
    }

    /// The owner app now (unnamed without a probe).
    pub fn owner_state(&self) -> OwnerState {
        self.owner
            .as_ref()
            .map_or(OwnerState::Unnamed, |probe| probe())
    }

    /// What live work keeps this host, None when nothing does.
    pub fn owner_exit_held_by(&self) -> Option<&'static str> {
        if !self.read_since_start {
            // A host started after the quit (another Chief woken by a
            // message) reads that message before it decides. No timer: the
            // first link Up or a failed connect ends it. Accepted gaps: a
            // first connect that fails for a moment (the owner daemon
            // restarting) or a catch-up that fails ends it too; the message
            // stays in the owner daemon and is read at the next wake (a new
            // message) or the next app start.
            return Some("the conversation is not read since the host started");
        }
        if !self.is_idle() {
            return Some("a turn runs or a prompt is queued");
        }
        if self.resume_at.is_some() || !self.state.resumes.is_empty() {
            return Some("a cut turn runs again");
        }
        if self.orphan_wait.is_some() {
            return Some("an adopted turn still runs");
        }
        if !self.unanswered.is_empty() {
            return Some("a permission request waits for an answer");
        }
        if self.state.spawns.values().any(|spawn| spawn.working()) {
            return Some("a subagent is at work");
        }
        if self.sessions.values().any(|s| {
            matches!(s.status, SessionStatus::Running | SessionStatus::Waiting)
                || s.pending_permissions > 0
        }) {
            return Some("a child session is at work");
        }
        if !self.state.wakes.is_empty() {
            return Some("a wake set with sleep is pending");
        }
        None
    }

    /// What keeps this host now.
    fn owner_keeps(&self) -> Keeps {
        Keeps {
            clients: false,
            owner: self.owner_state(),
            live_work: self.owner_exit_held_by().is_some(),
        }
    }

    /// Stops the brain when the rule says so; true then. Read after every
    /// input and timer.
    pub(super) fn stop_if_owner_gone(&mut self) -> bool {
        if self.fatal.is_some() {
            return false;
        }
        // A host no app named stays (unowned_keeps).
        if !self.owner_keeps().exits(true) {
            return false;
        }
        // The exit: the owner read again (its follow thread may have moved on).
        cmux_owner_liveness::check("optchat-chief host", true, self.owner_keeps(), true);
        (self.log)("the app quit and the Chief is idle: stopping");
        if self.outbox_timer.take().is_some() {
            self.flush_outbox();
        }
        self.save();
        self.fatal = Some(OWNER_APP_EXITED.into());
        true
    }
}
