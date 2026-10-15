public import Foundation

/// Memory Saver's busy-probe bookkeeping for one page: whether a probe is
/// running, and until when a page that answered "busy" is left alone.
///
/// Without it, every memory sample would start another probe on the same
/// busy page, and the memory budget would keep counting a page it cannot
/// free instead of moving on to the next one.
public struct BrowserPageReclaimProbe: Equatable, Sendable {
    /// How long a page that answered "busy" is not asked again.
    public static let busyBackoff: TimeInterval = 60

    /// A probe of this page is running.
    public var isRunning = false
    /// The page answered "busy" and is not asked again before this time.
    public var busyUntil: Date?

    /// Creates empty bookkeeping.
    public init() {}

    /// Whether the page may be probed (and counted as freeable) at `now`.
    /// - Parameter now: The current time.
    /// - Returns: `false` while a probe runs or a "busy" answer is recent.
    public func allowsProbe(now: Date) -> Bool {
        guard !isRunning else { return false }
        return busyUntil.map { now >= $0 } ?? true
    }
}
