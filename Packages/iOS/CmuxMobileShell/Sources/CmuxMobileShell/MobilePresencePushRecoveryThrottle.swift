import Foundation

/// Decides whether one presence delivery may start another recovery pass.
///
/// Presence heartbeats about an online Mac arrive roughly every 15 seconds.
/// While the phone is disconnected, each heartbeat used to restart connection
/// recovery, so during a persistent outage the phone kept abandoning its own
/// in-flight dials on the heartbeat cadence and each abandoned dial fed the
/// connect-registry gate
/// (https://github.com/manaflow-ai/cmux/issues/9177).
///
/// Changed evidence (new routes, a Mac coming online) always passes: that is
/// the wake-up signal presence exists for. Unchanged heartbeats pass at most
/// once per ``minimumUnchangedEvidenceInterval`` so an already-failing
/// recovery loop gets its full dial budget between presence-triggered
/// restarts.
struct MobilePresencePushRecoveryThrottle {
    /// Chosen above the ~15s presence heartbeat cadence and the dial budget a
    /// recovery pass needs, below the point where a stalled recovery would be
    /// user-visible next to the 30-60s automatic backoff ladder.
    static let minimumUnchangedEvidenceInterval: TimeInterval = 45

    private var lastRecoveryAt: Date?

    /// Records and reports whether a presence-triggered recovery may start.
    mutating func shouldRecover(evidenceChanged: Bool, now: Date) -> Bool {
        if evidenceChanged {
            lastRecoveryAt = now
            return true
        }
        guard let lastRecoveryAt else {
            self.lastRecoveryAt = now
            return true
        }
        let elapsed = now.timeIntervalSince(lastRecoveryAt)
        // A rewound wall clock (negative elapsed) must not freeze the
        // throttle until the clock catches back up; treat it as expired.
        guard elapsed >= 0, elapsed < Self.minimumUnchangedEvidenceInterval else {
            self.lastRecoveryAt = now
            return true
        }
        return false
    }

    /// Forgets throttle history at an account or session boundary.
    mutating func reset() {
        lastRecoveryAt = nil
    }
}
