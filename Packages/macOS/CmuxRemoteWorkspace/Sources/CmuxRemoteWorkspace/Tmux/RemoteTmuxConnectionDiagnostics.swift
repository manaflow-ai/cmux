import Foundation

/// A bounded ring of recent lifecycle/event strings for one remote-tmux control
/// connection, surfaced through `remote.tmux.state` diagnostics.
///
/// ``RemoteTmuxControlConnection`` records a short label for every notable event
/// (connect, exit, reconnect attempt, stream-end, write failure, …) here; the
/// buffer keeps only the most recent ``events`` up to the configured cap so a
/// long-lived connection on a chatty session can't grow it without limit.
@MainActor
public final class RemoteTmuxConnectionDiagnostics {
    /// The most recent recorded event labels, oldest first, capped at ``maxLines``.
    private var recentEvents: [String] = []
    /// The maximum number of event labels retained; older entries are dropped.
    private let maxLines: Int

    /// Creates a diagnostics buffer retaining at most `maxLines` recent events.
    ///
    /// - Parameter maxLines: the cap on retained event labels. Defaults to 100.
    public init(maxLines: Int = 100) {
        self.maxLines = maxLines
    }

    /// The retained event labels, oldest first.
    public var events: [String] { recentEvents }

    /// Appends `event`, trimming the buffer back to ``maxLines`` if it overflows.
    public func record(_ event: String) {
        recentEvents.append(event)
        if recentEvents.count > maxLines {
            recentEvents.removeFirst(recentEvents.count - maxLines)
        }
    }
}
