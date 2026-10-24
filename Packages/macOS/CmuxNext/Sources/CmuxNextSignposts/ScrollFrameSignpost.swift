public import Foundation

/// The always-on `key.scroll_frame` interval (``SignpostName/scrollToFrame``): from the app dispatching a scroll
/// event to the end of the Core Animation commit that ends that turn (``CommitBoundary``), the scroll twin of
/// ``KeyFrameSignpost``.
///
/// Begin message: `phase=<phase> age_ms=<age>`, the event's age when its dispatch began (its wait in the event
/// queue), so a reader adds that wait to the interval: input to frame. End message: `target=<layout|content>`.
/// A layout scroll applies its move in that turn, so its commit shows it; a scroll that went on to content may
/// show in a later frame, as a terminal key's echo does (``KeyFrameSignpost``).
///
/// ```swift
/// let end = ScrollFrameSignpost().begin(phase: .changed, eventTimestamp: event.timestamp)
/// end(.layout) // when the dispatch ended; the interval ends after the turn's commit
/// ```
public struct ScrollFrameSignpost: ScrollFrameTiming {
    /// A scroll-frame signposter.
    public init() {}

    /// Begins the interval for a scroll event dispatched now; its end closes it after this turn's commit.
    ///
    /// - Parameters:
    ///   - phase: Which part of a scroll the event is.
    ///   - eventTimestamp: The event's timestamp (seconds since boot, `NSEvent.timestamp`); 0 records age -1.
    /// - Returns: The end, called once when the dispatch ends with who took the event.
    public func begin(phase: ScrollFramePhase, eventTimestamp: TimeInterval) -> @MainActor (ScrollFrameTarget) -> Void {
        begin(phase: phase, eventTimestamp: eventTimestamp, now: ProcessInfo.processInfo.systemUptime)
    }

    /// ``begin(phase:eventTimestamp:)`` at `now` (seconds since boot, the event timestamp's clock).
    func begin(phase: ScrollFramePhase, eventTimestamp: TimeInterval, now: TimeInterval) -> @MainActor (ScrollFrameTarget) -> Void {
        let signposter = Signposter.key
        guard signposter.isEnabled else { return { _ in } }
        let interval = signposter.begin(.scrollToFrame, Self.beginMessage(phase: phase, eventTimestamp: eventTimestamp, now: now))
        return { target in
            CommitBoundary().after { outcome in signposter.end(.scrollToFrame, interval, outcome, message: "target=\(target.rawValue)") }
        }
    }

    /// The begin message: `phase=<phase> age_ms=<age>`, the age -1 when the event has no timestamp.
    static func beginMessage(phase: ScrollFramePhase, eventTimestamp: TimeInterval, now: TimeInterval) -> String {
        let age = eventTimestamp > 0 ? max(0, now - eventTimestamp) * 1000 : -1
        return "phase=\(phase.rawValue) age_ms=\(String(format: "%.2f", age))"
    }
}
