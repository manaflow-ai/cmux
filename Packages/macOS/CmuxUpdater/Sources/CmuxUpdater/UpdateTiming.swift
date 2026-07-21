public import Foundation

/// Fixed display/timeout durations that shape how the custom update UI behaves over time.
///
/// These are intentionally declarations (constant values), not behavior, so a no-case
/// `enum` namespace is appropriate here. They are consumed by ``UpdateDriver`` (to keep a
/// check visible for a minimum duration) and by ``UpdateController`` (to auto-dismiss the
/// authoritative "no updates" result).
public enum UpdateTiming {
    /// Minimum time the "Checking for Updates…" state stays visible before transitioning,
    /// so a near-instant check still reads as a deliberate action rather than a flicker.
    public static let minimumCheckDisplayDuration: TimeInterval = 2.0

    /// How long the "No Updates Available" result stays visible before auto-dismissing.
    public static let noUpdateDisplayDuration: TimeInterval = 5.0

}

/// How long the install flow may wait for Sparkle to start a fresh check or begin downloading an
/// accepted item before surfacing "Update Didn't Start." The authoritative feed check itself is
/// intentionally unbounded. Kept internal because this is controller policy, not public API.
let installWatchdogTimeout: TimeInterval = 25.0
