//! What a Mac's own view on the phone says about it (cmux#52200): the presence the cmux
//! service reports, this phone's link to it and the last failure, resolved into one state,
//! and the steps of one Retry. Swift's `MacReachability` and `MacRecoveryAttempt` keep the
//! copy and the dates; these are their rules.
//! Leo, 2026-11-23: "Cosmic Gray appears offline on my iOS phone. I cannot access or revive the
//! computer from iOS. I need that to be recoverable."

/// Why this phone's last try at a Mac failed, as far as the phone can tell.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MacLinkFailureKind {
    /// The phone dialed and the Mac never answered.
    HostUnreachable,
    /// The link opened, but cmux on the Mac did not answer or sent no workspaces.
    ServiceDown,
    /// The cmux service refused this account's session.
    AuthRequired,
    /// The Mac refused this iPhone.
    NotAllowed,
}

/// This phone's link to the Mac.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MacLinkState {
    Connecting,
    Connected,
    Failed,
}

/// What `mac_reachability_resolve` reads.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacReachabilityInput {
    /// What the cmux service lists.
    pub is_online: bool,
    /// The Mac's heartbeat quiet past the bound (`mac_reachability_late_quiet`), in ms.
    pub quiet_ms: Option<i64>,
    /// Nil: not linked.
    pub connection: Option<MacLinkState>,
    pub failure: Option<MacLinkFailureKind>,
    /// False in mock mode, where presence alone decides.
    pub live: bool,
    /// The device has no network.
    pub phone_offline: bool,
}

/// The Mac's state. Swift attaches the Mac's last-seen date to `Offline` and `NoAnswer`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MacReachabilityKind {
    Connected,
    Connecting,
    /// Online, the link is not on it (another Mac is linked).
    NotConnected,
    /// Listed online, its heartbeat quiet this long.
    Slow {
        quiet_seconds: i64,
    },
    /// The service says it is offline; nothing dialed it since.
    Offline,
    /// This phone dialed it and it never answered.
    NoAnswer {
        listed_online: bool,
    },
    ServiceDown,
    AuthRequired,
    NotAllowed,
    PhoneOffline,
}

/// The one thing a Mac's view offers when the phone can't use it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MacRecoveryActionKind {
    Retry,
    SignIn,
}

/// The service's freshness bound (`FRESH_MS` in backend/src/team-hub.ts): a Mac pings every
/// 15 s, so one quiet longer than this missed a heartbeat.
const FRESH_MILLIS: i64 = 18_000;

/// `quiet_ms` as the Mac's row keeps it: only past the bound, rounded down to 10 s.
#[uniffi::export]
pub fn mac_reachability_late_quiet(quiet_ms: Option<i64>) -> Option<i64> {
    let quiet = quiet_ms?;
    (quiet > FRESH_MILLIS).then_some(quiet / 10_000 * 10_000)
}

#[uniffi::export]
pub fn mac_reachability_resolve(input: MacReachabilityInput) -> MacReachabilityKind {
    use MacReachabilityKind as K;
    let MacReachabilityInput { is_online, quiet_ms, connection, failure, live, phone_offline } = input;
    if !live {
        return if is_online { K::Connected } else { K::Offline };
    }
    let linked = matches!(connection, Some(MacLinkState::Connected));
    if phone_offline && !linked {
        return K::PhoneOffline;
    }
    match failure {
        Some(MacLinkFailureKind::AuthRequired) => return K::AuthRequired,
        Some(MacLinkFailureKind::NotAllowed) => return K::NotAllowed,
        Some(MacLinkFailureKind::ServiceDown) => return K::ServiceDown,
        // A Mac the service lists offline is offline, whatever the dial said (cmux#52200).
        Some(MacLinkFailureKind::HostUnreachable)
            if !matches!(connection, Some(MacLinkState::Connected | MacLinkState::Connecting)) =>
        {
            return if is_online { K::NoAnswer { listed_online: true } } else { K::Offline };
        }
        _ => {}
    }
    match connection {
        Some(MacLinkState::Connected) => return K::Connected,
        Some(MacLinkState::Connecting) => return K::Connecting,
        Some(MacLinkState::Failed) | None => {}
    }
    if !is_online {
        return K::Offline;
    }
    if let Some(quiet) = quiet_ms {
        return K::Slow { quiet_seconds: quiet / 1000 };
    }
    if connection == Some(MacLinkState::Failed) {
        return K::NoAnswer { listed_online: true };
    }
    K::NotConnected
}

/// Retry or Sign In; nil while it is connected or on its way.
#[uniffi::export]
pub fn mac_reachability_action(state: MacReachabilityKind) -> Option<MacRecoveryActionKind> {
    use MacReachabilityKind as K;
    match state {
        K::Connected | K::Connecting | K::NotConnected => None,
        K::AuthRequired => Some(MacRecoveryActionKind::SignIn),
        K::Slow { .. }
        | K::Offline
        | K::NoAnswer { .. }
        | K::ServiceDown
        | K::NotAllowed
        | K::PhoneOffline => Some(MacRecoveryActionKind::Retry),
    }
}

/// "45 s", "3 min", "2 h".
#[uniffi::export]
pub fn mac_reachability_span(seconds: i64) -> String {
    if seconds < 60 {
        format!("{seconds} s")
    } else if seconds < 3600 {
        format!("{} min", seconds / 60)
    } else {
        format!("{} h", seconds / 3600)
    }
}

/// One Retry's steps, in order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, uniffi::Enum)]
pub enum MacRecoveryStep {
    /// Asking the cmux service (the relay) for the Mac's presence.
    Service,
    /// Dialing the Mac.
    Mac,
    /// The link is up; cmux on the Mac sends its workspaces and sessions.
    Session,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MacRecoveryResult {
    Connected,
    /// Stopped at this step.
    Failed {
        step: MacRecoveryStep,
    },
}

/// What the link shows while the attempt runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MacRecoveryObservation {
    Dialing,
    /// The link is up; the Mac's workspaces have not come yet.
    Linked,
    /// The Mac's workspaces came over the link.
    Live,
    Failed {
        failure: MacLinkFailureKind,
    },
    /// The dial ended with the Mac offline.
    Offline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct MacRecoveryAttemptState {
    pub step: MacRecoveryStep,
    pub result: Option<MacRecoveryResult>,
}

impl MacRecoveryAttemptState {
    fn running(&self) -> bool {
        self.result.is_none()
    }
}

/// One Retry over several Macs (All Macs): running while any runs, at the furthest step any
/// reached; connected once one connected; else failed at the furthest step. Nil with none.
#[uniffi::export]
pub fn mac_recovery_combined(attempts: Vec<MacRecoveryAttemptState>) -> Option<MacRecoveryAttemptState> {
    if attempts.is_empty() {
        return None;
    }
    if attempts.iter().any(|a| a.result == Some(MacRecoveryResult::Connected)) {
        return Some(MacRecoveryAttemptState {
            step: MacRecoveryStep::Session,
            result: Some(MacRecoveryResult::Connected),
        });
    }
    if let Some(step) = attempts.iter().filter(|a| a.running()).map(|a| a.step).max() {
        return Some(MacRecoveryAttemptState { step, result: None });
    }
    let step = attempts.iter().map(|a| a.step).max().unwrap_or(MacRecoveryStep::Service);
    Some(MacRecoveryAttemptState { step, result: Some(MacRecoveryResult::Failed { step }) })
}

/// The attempt after the link showed `observation`, once the service step passed.
#[uniffi::export]
pub fn mac_recovery_advanced(
    attempt: MacRecoveryAttemptState,
    observation: MacRecoveryObservation,
) -> MacRecoveryAttemptState {
    use MacRecoveryObservation as O;
    if !attempt.running() || attempt.step < MacRecoveryStep::Mac {
        return attempt;
    }
    let failed = |step| Some(MacRecoveryResult::Failed { step });
    let mut next = attempt;
    match observation {
        O::Dialing => {}
        O::Linked => next.step = MacRecoveryStep::Session,
        O::Live => {
            next.step = MacRecoveryStep::Session;
            next.result = Some(MacRecoveryResult::Connected);
        }
        O::Offline | O::Failed { failure: MacLinkFailureKind::HostUnreachable } => {
            next.result = failed(MacRecoveryStep::Mac);
        }
        O::Failed { failure: MacLinkFailureKind::ServiceDown } => {
            next.result = failed(MacRecoveryStep::Session);
        }
        O::Failed { failure: MacLinkFailureKind::AuthRequired | MacLinkFailureKind::NotAllowed } => {
            next.result = failed(attempt.step);
        }
    }
    next
}

/// The attempt when its deadline passed with no result: failed where it stood.
#[uniffi::export]
pub fn mac_recovery_timed_out(attempt: MacRecoveryAttemptState) -> MacRecoveryAttemptState {
    if !attempt.running() {
        return attempt;
    }
    MacRecoveryAttemptState {
        step: attempt.step,
        result: Some(MacRecoveryResult::Failed { step: attempt.step }),
    }
}

#[cfg(test)]
#[path = "mac_reachability_tests.rs"]
mod tests;
