public import CmuxNextFocus

/// W11 (plans/cmux-next/focus-invariant.md): a window's focus expectation (a target that lands later: the daemon's
/// tab of a new browser tab, a split's terminal) that is still pending `limit` after its create's key hold ended
/// never landed, and the keys go to the old target meanwhile. A create that failed leaves its expectation until a
/// newer intent; that is reported too (the keys went nowhere new). Keeps, per window, the expectation seen last and when it was
/// first seen; a different expectation (a newer intent) starts its own clock. Pure: the monitor passes the time.
public nonisolated struct FocusExpectationAges: Sendable {
    private var seen: [String: Entry] = [:]

    private struct Entry: Sendable {
        var key: String
        var since: ContinuousClock.Instant
    }

    public init() {}

    /// Records the expectations of `windows` at `now`.
    /// - Parameter holding: Windows whose keys still wait for a create's reply (`CreationInputCoordinator`, the New
    ///   Tab hold): their clock starts when the hold ends, since a slow daemon or a remote workspace may keep a
    ///   legitimate create waiting longer than `limit`.
    /// - Returns: A W11 violation per window whose expectation has waited `limit` or longer, and the time the
    ///   oldest pending expectation was first seen (nil when none is pending).
    public mutating func check(_ windows: [InputObservation.Window], now: ContinuousClock.Instant, limit: Duration,
                               holding: Set<String> = []) -> (violations: [InputViolation], oldest: ContinuousClock.Instant?) {
        var next: [String: Entry] = [:]
        var out: [InputViolation] = []
        for window in windows {
            guard let expectation = window.model.expectation else { continue }
            // One intent's expectation keeps its clock when it is re-keyed from a surface to its tab
            // (`rekeySurfaceWait` keeps the generation and target).
            let key = "\(expectation.target) generation \(expectation.generation)"
            let since = holding.contains(window.id) ? now : seen[window.id].flatMap { $0.key == key ? $0.since : nil } ?? now
            next[window.id] = Entry(key: key, since: since)
            let waited = now - since
            if waited >= limit {
                let millis = waited.components.seconds * 1000 + waited.components.attoseconds / 1_000_000_000_000_000
                out.append(InputViolation(invariant: .expectationLands, window: window.id,
                                          detail: "focus on \(expectation.key) (\(expectation.target)) pending for \(millis) ms; "
                                              + "the keys go to \(window.model.resolved.kind)"))
            }
        }
        seen = next
        return (out, next.values.map(\.since).min())
    }
}
