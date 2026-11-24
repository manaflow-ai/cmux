public import Foundation

/// The always-on `switch.wake` interval (``SignpostName/switchWake``): from the system or a display waking to
/// the end of the Core Animation commit of the first main-thread turn after it (``CommitBoundary``).
///
/// Message: `source=<system|display>`. The optimum is one frame (16.7 ms); the ledger row
/// `wake-display-to-interactive` reads this interval.
///
/// ```swift
/// WakeFrameSignpost().begin(source: .display)
/// ```
public struct WakeFrameSignpost: Sendable {
    /// What woke.
    public enum Source: String, Sendable {
        /// The Mac (`NSWorkspace.didWakeNotification`).
        case system
        /// A display (`NSWorkspace.screensDidWakeNotification`).
        case display
    }

    /// A wake signposter.
    public init() {}

    /// Begins the interval for a wake observed now; it ends after this main run-loop turn's commit.
    @MainActor
    public func begin(source: Source) {
        let signposter = Signposter.switch
        guard signposter.isEnabled else { return }
        let interval = signposter.begin(.switchWake, "source=\(source.rawValue)")
        CommitBoundary().after { outcome in signposter.end(.switchWake, interval, outcome) }
    }
}
