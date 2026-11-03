public import Foundation

/// The always-on `key.frame` interval (``SignpostName/keyToFrame``): from the app dispatching a key-down to the end
/// of the Core Animation commit that ends that turn (``CommitBoundary``).
///
/// Message: `target=<view|terminal> age_ms=<age>`, the key's age when its dispatch began (its wait in the event
/// queue), so a reader adds that wait to the interval. For a text view (the Home composer, the omnibar, a field) the
/// commit carries the typed character; for a terminal it carries the key's own work only, and the echo comes back
/// from the shell in a later frame, so `target=terminal` rows are the main thread's share of the key.
///
/// ```swift
/// KeyFrameSignpost().begin(target: .view, eventTimestamp: event.timestamp)
/// ```
public struct KeyFrameSignpost: Sendable {
    /// What has the keyboard when the key is dispatched.
    public enum Target: String, Sendable {
        /// A text view or any view that is not a terminal: the commit shows the typed character.
        case view
        /// A terminal: the commit shows the key's own work; the echo is a later frame.
        case terminal
    }

    /// A key-frame signposter.
    public init() {}

    /// Begins the interval for a key-down dispatched now; it ends after this main run-loop turn's commit.
    ///
    /// - Parameters:
    ///   - target: What has the keyboard.
    ///   - eventTimestamp: The key event's timestamp (seconds since boot, `NSEvent.timestamp`); 0 records age -1.
    ///   - now: Seconds since boot now (`ProcessInfo.systemUptime`, the event timestamp's clock).
    @MainActor
    public func begin(target: Target, eventTimestamp: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let signposter = Signposter.key
        guard signposter.isEnabled else { return }
        let age = eventTimestamp > 0 ? max(0, now - eventTimestamp) * 1000 : -1
        let interval = signposter.begin(.keyToFrame, "target=\(target.rawValue) age_ms=\(String(format: "%.2f", age))")
        CommitBoundary().after { outcome in signposter.end(.keyToFrame, interval, outcome) }
    }
}
