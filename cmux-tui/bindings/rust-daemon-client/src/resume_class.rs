//! How each way a daemon session ends is classified for the worker's
//! reconnect: every failure of [`crate::client`]'s `session` carries a
//! [`ResumeErrorClass`], read from the error's kind or variant (never its
//! text), and the worker's [`acpmux_list_types::resume::ResumeBudget`]
//! decides the wait and the step.

use crate::attach::{AttachEnd, EndReason};
use crate::launcher::LaunchError;
use crate::mirror::MirrorError;
pub use acpmux_list_types::resume::ResumeErrorClass;

/// Why one connected session (or its attempt) ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SessionEnd {
    pub class: ResumeErrorClass,
    pub error: String,
}

impl SessionEnd {
    pub(crate) fn new(class: ResumeErrorClass, error: impl Into<String>) -> Self {
        Self { class, error: error.into() }
    }

    /// An SDK call `what` failed.
    pub(crate) fn sdk(what: &str, e: &cmux::Error) -> Self {
        Self::new(sdk_class(e), format!("{what}: {e}"))
    }

    /// Finding or starting the daemon failed.
    pub(crate) fn launch(e: &LaunchError) -> Self {
        Self::new(launch_class(e), e.to_string())
    }

    /// The mirror could not apply a delta: its revision no longer follows
    /// the daemon's, so only a new snapshot can resume it.
    pub(crate) fn mirror(e: &MirrorError) -> Self {
        Self::new(mirror_class(e), format!("resync: {e}"))
    }

    /// The daemon ended the event stream normally.
    pub(crate) fn stream_ended() -> Self {
        Self::new(ResumeErrorClass::CleanClose, "event stream ended")
    }
}

/// The class of an SDK error. The SDK's error is `non_exhaustive`, so a
/// variant this match does not name is [`ResumeErrorClass::Unknown`]: one
/// retry, then surfaced, never retried without a bound.
pub fn sdk_class(e: &cmux::Error) -> ResumeErrorClass {
    use ResumeErrorClass as C;
    use cmux::Error as E;
    match e {
        E::ConnectionIo { kind, .. } => C::from_io_kind(*kind),
        E::Connection(_) => C::Transient,
        E::Timeout(_) => C::DeadlineExceeded,
        E::AuthorityDenied { .. } => C::Auth,
        E::Protocol { retryable: true, .. } => C::Transient,
        E::QueueOverflow { .. } => C::Transient,
        E::MutationTransport { source, .. } => sdk_class(source),
        E::StreamEnded { error: Some(source), .. } => sdk_class(source),
        E::StreamEnded { error: None, .. } | E::Closed | E::Cancelled(_) => C::CleanClose,
        _ => C::Unknown,
    }
}

/// The class of a failure to find or start the daemon.
pub fn launch_class(e: &LaunchError) -> ResumeErrorClass {
    match e {
        LaunchError::Spawn(io) => ResumeErrorClass::from_io_kind(io.kind()),
        LaunchError::Timeout(_) => ResumeErrorClass::DeadlineExceeded,
        LaunchError::BinaryNotFound(_) | LaunchError::Failed { .. } | LaunchError::Parse(_) => {
            ResumeErrorClass::Unknown
        }
    }
}

/// Every mirror error means its revision no longer follows the daemon's.
pub fn mirror_class(e: &MirrorError) -> ResumeErrorClass {
    match e {
        MirrorError::NoBaseline
        | MirrorError::GenerationChanged { .. }
        | MirrorError::RevisionGap { .. }
        | MirrorError::Mismatch(_)
        | MirrorError::InvalidState { .. } => ResumeErrorClass::GapTooOld,
    }
}

/// The class of an ended terminal attachment, for a caller deciding whether
/// to call [`crate::reattach`].
pub fn attach_end_class(end: &AttachEnd) -> ResumeErrorClass {
    use ResumeErrorClass as C;
    use cmux::raw::DetachReason as D;
    match end {
        AttachEnd::Released | AttachEnd::Replaced => C::CleanClose,
        // What the attach named is no longer in the daemon: re-read the
        // mirror, never retry the old identity.
        AttachEnd::TerminalGone(_) => C::GapTooOld,
        AttachEnd::Interrupted { reason, .. } => match reason {
            EndReason::Overflow => C::GapTooOld,
            EndReason::ClosedByClient => C::CleanClose,
            EndReason::ConnectionLost(_) => C::Transient,
            EndReason::Detached {
                reason: Some(D::HostShutdown | D::DisconnectedBy | D::Superseded),
                ..
            } => C::CleanClose,
            EndReason::Detached { reason: Some(D::Network) | None, .. } => C::Transient,
        },
        AttachEnd::Failed(_) => C::Unknown,
    }
}

#[cfg(test)]
#[path = "resume_class_tests.rs"]
mod tests;
