/// The time a person used cmux: a hang report's `active_seconds`, the denominator of its hang and
/// turn counts. Chrome's rule (chrome/browser/metrics/desktop_session_duration/
/// desktop_session_duration_tracker.cc): a span starts when the app becomes active or, while it is,
/// at the person's input; it ends when the app resigns active, or when no input came for the
/// inactivity timeout (5 minutes), and then it ends at the last input: the timeout is not counted
/// (Chrome's `EndSession(inactivity_timeout_)`). So cmux left frontmost overnight while agents run
/// counts nothing past the last key or click.
///
/// A value type with the caller's clock: every stamp is uptime nanoseconds (`CLOCK_UPTIME_RAW`,
/// which stops while the Mac sleeps). Time after the last input of an open span is not yet known
/// to be active: a read counts the span up to that input, and the rest counts once the next input
/// or the resign-active notice arrives within the timeout. A stamp older than the open span's start
/// counts nothing. `stability.active_seconds` (not built yet) is to count with
/// this type, so the two denominators agree.
///
/// ```swift
/// ledger.didBecomeActive(atNanos: now)
/// ledger.didReceiveUserInput(atNanos: event)
/// let seconds = ledger.seconds(atNanos: now)          // build the report with it ...
/// ledger.commit(seconds: seconds, atNanos: now)       // ... once that report is queued
/// ```
public nonisolated struct ActiveTimeLedger: Sendable, Equatable {
    /// Chrome's inactivity timeout (`kInactivityTimeoutMinutes`, 5 minutes).
    public static let defaultInactivityTimeoutNanos: UInt64 = 5 * 60 * nanosPerSecond
    static let nanosPerSecond: UInt64 = 1_000_000_000

    /// How long without input ends a span.
    public let inactivityTimeoutNanos: UInt64
    /// Active time counted and not yet committed, not including the open span.
    private var countedNanos: UInt64 = 0
    /// Whether the app is the active app (between a became-active and a resign-active notice).
    public private(set) var isActive = false
    /// Where the open span's uncounted time starts; nil when no span is open (inactive, or idle past
    /// the timeout).
    private var spanStartNanos: UInt64?
    /// The open span's last input (or its activation).
    private var lastInputNanos: UInt64 = 0

    /// Makes an empty ledger for an app that is not active.
    public init(inactivityTimeoutNanos: UInt64 = ActiveTimeLedger.defaultInactivityTimeoutNanos) {
        self.inactivityTimeoutNanos = inactivityTimeoutNanos
    }

    /// The app became active at `nanos`: a span starts, or the open one sees input.
    public mutating func didBecomeActive(atNanos nanos: UInt64) {
        isActive = true
        noteInput(atNanos: nanos)
    }

    /// The person's input at `nanos` (a key, click or scroll): keeps the open span going, or starts
    /// one after an idle timeout. Ignored while the app is not active.
    public mutating func didReceiveUserInput(atNanos nanos: UInt64) {
        guard isActive else { return }
        noteInput(atNanos: nanos)
    }

    /// The app stopped being active at `nanos`: the open span is counted up to it (or to its last
    /// input when it timed out before) and closed.
    public mutating func didResignActive(atNanos nanos: UInt64) {
        settle(atNanos: nanos, confirmed: true)
        spanStartNanos = nil
        isActive = false
    }

    /// The whole active seconds not yet committed, including the open span up to its last input.
    public func seconds(atNanos nanos: UInt64) -> Int {
        Int(clamping: countedNanos(atNanos: nanos) / Self.nanosPerSecond)
    }

    /// The active nanoseconds not yet committed, including the open span up to its last input (what
    /// a save keeps for the next launch: the uptime clock restarts at boot, so a span cannot be kept).
    public func countedNanos(atNanos nanos: UInt64) -> UInt64 {
        var ledger = self
        ledger.settle(atNanos: nanos, confirmed: false)
        return ledger.countedNanos
    }

    /// The report holding `seconds` (an earlier ``seconds(atNanos:)``) was queued: they leave the
    /// ledger, and the fraction of a second and anything counted since stay for the next report.
    public mutating func commit(seconds: Int, atNanos nanos: UInt64) {
        settle(atNanos: nanos, confirmed: false)
        let (sent, overflow) = UInt64(max(0, seconds)).multipliedReportingOverflow(by: Self.nanosPerSecond)
        countedNanos = overflow ? 0 : countedNanos - min(countedNanos, sent)
    }

    /// Drops everything counted up to `nanos` and keeps the span state (reports turned on or off:
    /// time before that is never sent).
    public mutating func discardCounted(atNanos nanos: UInt64) {
        settle(atNanos: nanos, confirmed: true)
        countedNanos = 0
    }

    /// Adds active time an earlier launch saved (``countedNanos(atNanos:)``).
    public mutating func add(savedNanos: UInt64) {
        countedNanos = Self.adding(countedNanos, savedNanos)
    }

    private mutating func noteInput(atNanos nanos: UInt64) {
        settle(atNanos: nanos, confirmed: true)
        if spanStartNanos == nil { spanStartNanos = nanos }
        lastInputNanos = max(lastInputNanos, nanos)
    }

    /// Counts the open span's known-active time at `nanos`. Past the timeout the span ends at its last
    /// input. Otherwise a `confirmed` stamp (an input or the resign) counts up to it; a read counts
    /// up to the last input and leaves the rest open.
    private mutating func settle(atNanos nanos: UInt64, confirmed: Bool) {
        guard let start = spanStartNanos, nanos > start else { return }
        let (idleAt, overflow) = lastInputNanos.addingReportingOverflow(inactivityTimeoutNanos)
        if !overflow, nanos >= idleAt {
            count(from: start, to: lastInputNanos)
            spanStartNanos = nil
            return
        }
        let end = confirmed ? nanos : min(nanos, lastInputNanos)
        count(from: start, to: end)
        spanStartNanos = max(start, end)
    }

    private mutating func count(from start: UInt64, to end: UInt64) {
        guard end > start else { return }
        countedNanos = Self.adding(countedNanos, end - start)
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
