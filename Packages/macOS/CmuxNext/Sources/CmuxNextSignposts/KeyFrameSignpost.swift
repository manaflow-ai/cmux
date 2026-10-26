public import Foundation

/// The always-on `key.frame` interval (``SignpostName/keyToFrame``): from the app dispatching a key-down to the end
/// of the Core Animation commit that ends that turn (``CommitBoundary``).
///
/// Message: `target=<view|terminal> age_ms=<age>`, the key's age when its dispatch began (its wait in the event
/// queue), so a reader adds that wait to the interval. For a text view (the Home composer, the omnibar, a field) the
/// commit carries the typed character; for a terminal it carries the key's own work only, and the echo comes back
/// from the shell in a later frame, so `target=terminal` rows are the main thread's share of the key.
///
/// It runs on every key for every user, so the signpost itself makes no heap allocation: the typed begin and end
/// (``Signposter/begin(_:target:ageMicros:)``) format numbers into a stack buffer, never a `String`.
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
        let interval = signposter.begin(.keyToFrame, target: target,
                                        ageMicros: Self.ageMicros(eventTimestamp: eventTimestamp, now: now))
        CommitBoundary().after { outcome in signposter.end(.keyToFrame, interval, outcome) }
    }

    /// The key's age in microseconds (rounded) when its dispatch began (never negative), -1 when it has no timestamp.
    static func ageMicros(eventTimestamp: TimeInterval, now: TimeInterval) -> Int64 {
        eventTimestamp > 0 ? Int64((max(0, now - eventTimestamp) * 1_000_000).rounded()) : -1
    }
}
