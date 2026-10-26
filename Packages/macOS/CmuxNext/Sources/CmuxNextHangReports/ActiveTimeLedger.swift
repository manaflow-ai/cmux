/// The time cmux was the active app, from its activation notices (`NSApplication.didBecomeActive`
/// and `didResignActive`): a hang report's `active_seconds`, the denominator of its hang and turn
/// counts. Chrome measures the same thing to normalize its field data
/// (chrome/browser/metrics/desktop_session_duration/desktop_session_duration_tracker.cc: a session
/// starts when a browser window becomes active and ends when none is, `Session.TotalDuration`).
///
/// A value type with the caller's clock: every stamp is uptime nanoseconds (`CLOCK_UPTIME_RAW`,
/// which stops while the Mac sleeps, so a sleeping Mac adds no active time). A repeated notice is
/// ignored, and a stamp older than the open span's start counts nothing.
///
/// ```swift
/// ledger.didBecomeActive(atNanos: now)
/// let seconds = ledger.seconds(atNanos: now)          // build the report with it ...
/// ledger.commit(seconds: seconds, atNanos: now)       // ... once that report is queued
/// ```
public nonisolated struct ActiveTimeLedger: Sendable, Equatable {
    private static let nanosPerSecond: UInt64 = 1_000_000_000

    /// Active time counted and not yet committed, not including the open span.
    private var countedNanos: UInt64 = 0
    /// When the app became active, while it is.
    private var activeSinceNanos: UInt64?

    /// Makes an empty ledger for an app that is not active.
    public init() {}

    /// Whether the app is active now (between a became-active and a resign-active notice).
    public var isActive: Bool { activeSinceNanos != nil }

    /// The app became active at `nanos`; ignored while it already is.
    public mutating func didBecomeActive(atNanos nanos: UInt64) {
        guard activeSinceNanos == nil else { return }
        activeSinceNanos = nanos
    }

    /// The app stopped being active at `nanos`: the open span is counted and closed.
    public mutating func didResignActive(atNanos nanos: UInt64) {
        fold(atNanos: nanos)
        activeSinceNanos = nil
    }

    /// The whole active seconds not yet committed, including the open span up to `nanos`.
    public func seconds(atNanos nanos: UInt64) -> Int {
        var ledger = self
        ledger.fold(atNanos: nanos)
        return Int(clamping: ledger.countedNanos / Self.nanosPerSecond)
    }

    /// The report holding `seconds` (an earlier ``seconds(atNanos:)``) was queued: they leave the
    /// ledger, and the fraction of a second and anything counted since stay for the next report.
    public mutating func commit(seconds: Int, atNanos nanos: UInt64) {
        fold(atNanos: nanos)
        let (sent, overflow) = UInt64(max(0, seconds)).multipliedReportingOverflow(by: Self.nanosPerSecond)
        countedNanos = overflow ? 0 : countedNanos - min(countedNanos, sent)
    }

    /// Moves the open span up to `nanos` into ``countedNanos`` and restarts it at `nanos`.
    private mutating func fold(atNanos nanos: UInt64) {
        guard let since = activeSinceNanos, nanos > since else { return }
        let (sum, overflow) = countedNanos.addingReportingOverflow(nanos - since)
        countedNanos = overflow ? .max : sum
        activeSinceNanos = nanos
    }
}
