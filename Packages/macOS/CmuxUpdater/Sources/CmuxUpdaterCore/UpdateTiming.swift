public import Foundation

/// Fixed display/timeout durations that shape how the custom update UI behaves over time.
///
/// These are intentionally declarations (constant values), not behavior, so a no-case
/// `enum` namespace is appropriate here. They are consumed by ``UpdateDriver`` (to time out a
/// stalled check) and by ``UpdateController`` (to auto-dismiss the "no updates" result).
///
/// There is no minimum "Checking for Updates…" time: a check shows its answer the moment
/// Sparkle has read the feed (about 0.25 s for the 1 KB nightly appcast). A fixed 2 s minimum
/// made every check read as slow (`plans/cmux-next/update-check-PERF.md`).
public enum UpdateTiming {
    /// How long the "No Updates Available" result stays visible before auto-dismissing.
    public static let noUpdateDisplayDuration: TimeInterval = 5.0

    /// How long a check may stay in the "checking" state before it is treated as a
    /// silent "no updates" result (covers a Sparkle check that never calls back).
    public static let checkTimeoutDuration: TimeInterval = 10.0

}

/// How long after the user asks to install an update the flow may stay in a non-progressing
/// state (still checking or still merely "update available") before the updater surfaces a
/// visible "Update Didn't Start" error instead of silently doing nothing. Kept internal because
/// this is controller policy, not public timing API.
let installWatchdogTimeout: TimeInterval = 25.0
