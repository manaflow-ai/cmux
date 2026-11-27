//! Resume failures sorted by what they mean, each class with its own retry
//! bound and its own next step.
//!
//! A resume (a client re-following a daemon, a peer re-dialing a mirror, a
//! chat re-attaching from its cursor) can fail for reasons that need opposite
//! answers: a cursor the log no longer holds will fail the same way on every
//! retry, while a refused socket during a daemon restart passes a moment later.
//! Every resume failure site maps its own typed error into one
//! [`ResumeErrorClass`] (by kind or code, never by message text), and a
//! [`ResumeBudget`] answers each failure with a [`Decision`]: take the class's
//! step after a bounded wait, or, once the class's attempts are spent,
//! [`Decision::Surface`]. No class retries without a bound.
//!
//! The shape follows remote-execution error classification in build
//! systems: sort a remote error into a category first, then let the category
//! decide whether to retry and what to report.

use std::io;
use std::time::Duration;

/// What a resume failure means, which decides how it is answered.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ResumeErrorClass {
    /// The resume cursor (sequence, revision, page mark) is older than what
    /// the log or ring still holds, or the stream it named was replaced.
    /// Retrying the same cursor fails the same way: resync from a snapshot.
    GapTooOld,
    /// A call, connect or handshake ran past its deadline.
    DeadlineExceeded,
    /// The peer closed the stream normally (end of stream, a close frame, a
    /// restart notice). Nothing to retry: attach again from scratch.
    CleanClose,
    /// The credential was refused or has expired. Refresh it once; a second
    /// refusal will not pass by retrying.
    Auth,
    /// The network or socket failed (refused, reset, broken pipe, not yet
    /// listening): a later attempt may pass.
    Transient,
    /// Anything a site cannot name. One retry, then surface it.
    Unknown,
}

/// What the resuming side does about a failure.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum NextStep {
    /// Resume again from the same cursor.
    RetrySameCursor,
    /// Drop the cursor and rebuild from a full snapshot.
    FullResync,
    /// Attach again as a new follower, with no cursor.
    ReattachFresh,
    /// Load the credential again, then resume.
    RefreshCredential,
}

/// One class's retry bound: how many times its step is taken in a row before
/// the failure is surfaced, and the wait before each one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResumePolicy {
    /// The step each failure of this class takes while attempts remain.
    pub step: NextStep,
    /// How many failures in a row (with no success between) take the step.
    pub attempts: u32,
    /// The wait before the first step; it doubles for each later one.
    pub first_wait: Duration,
    /// The longest wait before any step.
    pub most_wait: Duration,
}

impl ResumePolicy {
    /// The wait before the step of attempt `attempt` (0-based): `first_wait`
    /// doubled `attempt` times, at most `most_wait`.
    pub fn wait(&self, attempt: u32) -> Duration {
        self.first_wait.saturating_mul(1u32 << attempt.min(16)).min(self.most_wait)
    }

    /// The sum of every wait the class can take before it surfaces.
    pub fn total_wait(&self) -> Duration {
        (0..self.attempts).map(|attempt| self.wait(attempt)).sum()
    }
}

impl ResumeErrorClass {
    /// Every class, in a fixed order.
    pub const ALL: [ResumeErrorClass; 6] = [
        ResumeErrorClass::GapTooOld,
        ResumeErrorClass::DeadlineExceeded,
        ResumeErrorClass::CleanClose,
        ResumeErrorClass::Auth,
        ResumeErrorClass::Transient,
        ResumeErrorClass::Unknown,
    ];

    /// This class's retry bound and next step.
    pub const fn policy(self) -> ResumePolicy {
        const NOW: Duration = Duration::ZERO;
        match self {
            // Resync at once; a second gap with no success between surfaces.
            ResumeErrorClass::GapTooOld => ResumePolicy {
                step: NextStep::FullResync,
                attempts: 2,
                first_wait: NOW,
                most_wait: NOW,
            },
            ResumeErrorClass::DeadlineExceeded => ResumePolicy {
                step: NextStep::RetrySameCursor,
                attempts: 3,
                first_wait: Duration::from_secs(1),
                most_wait: Duration::from_secs(4),
            },
            // No retry of the old stream: a fresh attach, at once.
            ResumeErrorClass::CleanClose => ResumePolicy {
                step: NextStep::ReattachFresh,
                attempts: 3,
                first_wait: NOW,
                most_wait: NOW,
            },
            // Refresh once, then stop.
            ResumeErrorClass::Auth => ResumePolicy {
                step: NextStep::RefreshCredential,
                attempts: 1,
                first_wait: NOW,
                most_wait: NOW,
            },
            ResumeErrorClass::Transient => ResumePolicy {
                step: NextStep::RetrySameCursor,
                attempts: 8,
                first_wait: Duration::from_millis(250),
                most_wait: Duration::from_secs(10),
            },
            ResumeErrorClass::Unknown => ResumePolicy {
                step: NextStep::RetrySameCursor,
                attempts: 1,
                first_wait: Duration::from_secs(1),
                most_wait: Duration::from_secs(1),
            },
        }
    }

    /// The class's stable name, for logs and wire fields.
    pub const fn as_str(self) -> &'static str {
        match self {
            ResumeErrorClass::GapTooOld => "gap_too_old",
            ResumeErrorClass::DeadlineExceeded => "deadline_exceeded",
            ResumeErrorClass::CleanClose => "clean_close",
            ResumeErrorClass::Auth => "auth",
            ResumeErrorClass::Transient => "transient",
            ResumeErrorClass::Unknown => "unknown",
        }
    }

    /// The class of a socket or file error, by its kind.
    pub fn from_io_kind(kind: io::ErrorKind) -> Self {
        use io::ErrorKind as K;
        match kind {
            K::TimedOut => ResumeErrorClass::DeadlineExceeded,
            K::PermissionDenied => ResumeErrorClass::Auth,
            K::ConnectionRefused
            | K::ConnectionReset
            | K::ConnectionAborted
            | K::NotConnected
            | K::BrokenPipe
            | K::NotFound
            | K::AddrNotAvailable
            | K::AddrInUse
            | K::Interrupted
            | K::WouldBlock
            | K::UnexpectedEof
            | K::HostUnreachable
            | K::NetworkUnreachable
            | K::NetworkDown
            | K::ResourceBusy => ResumeErrorClass::Transient,
            _ => ResumeErrorClass::Unknown,
        }
    }

    fn index(self) -> usize {
        self as usize
    }
}

impl std::fmt::Display for ResumeErrorClass {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The answer to one resume failure.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Take `step` after `after`. `attempt` counts from 1 within its class.
    Act { step: NextStep, after: Duration, attempt: u32 },
    /// The class's attempts are spent: report `class` to the caller, which
    /// stops resuming fast (a long-lived link waits for a wake or its own
    /// slow park interval, then calls [`ResumeBudget::reset`]).
    Surface { class: ResumeErrorClass, attempts: u32 },
}

/// The attempts each class has spent since the last successful resume.
///
/// Counters only fall back to zero on [`ResumeBudget::on_success`] or
/// [`ResumeBudget::reset`], so failures that alternate between classes are
/// bounded too: at most the sum of every class's attempts before one
/// surfaces.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ResumeBudget {
    used: [u32; 6],
}

impl ResumeBudget {
    pub fn new() -> Self {
        Self::default()
    }

    /// The answer to a failure of `class`.
    pub fn on_failure(&mut self, class: ResumeErrorClass) -> Decision {
        let policy = class.policy();
        let used = &mut self.used[class.index()];
        if *used >= policy.attempts {
            return Decision::Surface { class, attempts: *used };
        }
        let attempt = *used;
        *used += 1;
        Decision::Act { step: policy.step, after: policy.wait(attempt), attempt: attempt + 1 }
    }

    /// A resume succeeded: every class has its whole budget again.
    pub fn on_success(&mut self) {
        self.used = [0; 6];
    }

    /// Starts over after a surfaced failure, when the caller tries again on
    /// its own slow schedule or a wake.
    pub fn reset(&mut self) {
        self.on_success();
    }

    /// The attempts `class` has spent since the last success.
    pub fn used(&self, class: ResumeErrorClass) -> u32 {
        self.used[class.index()]
    }
}

#[cfg(test)]
#[path = "resume_tests.rs"]
mod tests;
