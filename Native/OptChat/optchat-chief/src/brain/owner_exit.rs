//! The app that this host serves exited (`owner_app.rs`): an idle brain
//! stops, so the host ends with what it started (its acpmux), and the
//! Chief's owner daemon follows once no client is left (cmux-tui
//! `headless/chief_owner_exit.rs`). cp/quit-chief-idle, 2026-10-27: after a
//! Cmd-Q these ran on, idle, about 300 MB.
//!
//! Live work keeps the host (Keep Sessions Running keeps the Chief
//! working): a turn that runs or waits for the compactor, a queued prompt,
//! a steer on its way, a cut turn that runs again, an adopted turn, a
//! permission request nobody answered yet, a subagent or a child session at
//! work, a wake the Chief set with `sleep`. Each input and timer looks again;
//! the brain stops at the first look that finds none. Before it stops it
//! sends what its outbox holds, as a handoff does.

use std::time::{Duration, Instant};

use cmux_chief::acp::SessionStatus;

use super::Brain;

/// The brain's stop once its app exited and nothing keeps it.
pub const OWNER_APP_EXITED: &str = "the app quit and the Chief is idle";

/// How long a host whose app exited waits for its owner daemon's link, so
/// a message the person sent before the quit is read first; past it the
/// host stops without (the next host reads it).
pub(super) const LINK_WAIT: Duration = Duration::from_secs(30);

impl Brain {
    /// The app exited (`Input::OwnerAppExited`).
    pub(super) fn owner_app_exited(&mut self) {
        if self.owner_gone_at.is_none() {
            (self.log)("the app quit: the Chief stops once it is idle");
            self.owner_gone_at = Some(Instant::now());
        }
        self.stop_if_owner_gone();
    }

    /// What keeps this host after its app exited, None when nothing does.
    pub fn owner_exit_held_by(&self) -> Option<&'static str> {
        if !self.is_idle() {
            return Some("a turn runs or a prompt is queued");
        }
        if self.daemon.is_none() && self.owner_gone_at.is_none_or(|at| at.elapsed() < LINK_WAIT) {
            return Some("the conversation link is not up yet");
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

    /// Stops the brain when its app exited and nothing keeps it; true then.
    pub(super) fn stop_if_owner_gone(&mut self) -> bool {
        if self.owner_gone_at.is_none() || self.fatal.is_some() {
            return false;
        }
        if self.owner_exit_held_by().is_some() {
            return false;
        }
        (self.log)("the app quit and the Chief is idle: stopping");
        if self.outbox_timer.take().is_some() {
            self.flush_outbox();
        }
        self.save();
        self.fatal = Some(OWNER_APP_EXITED.into());
        true
    }

    /// When a host whose app exited stops waiting for its link.
    pub(super) fn owner_link_deadline(&self) -> Option<Instant> {
        self.owner_gone_at
            .filter(|_| self.daemon.is_none() && self.fatal.is_none())
            .map(|at| at + LINK_WAIT)
    }
}
