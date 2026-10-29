public import CmuxNextFocus

/// W11 (plans/cmux-next/focus-invariant.md): a window's focus expectation (a target that lands later: the daemon's
/// tab of a new browser tab, a split's terminal) that is still pending `limit` after its create's key hold ended
/// never landed, and the keys go to the old target meanwhile. A create that failed leaves its expectation until a
/// newer intent; that is reported too (the keys went nowhere new). Keeps, per window, the expectation seen last and when it was
/// first seen; a different expectation (a newer intent) starts its own clock. Pure: the caller passes the time. The
/// invariant registry's W11 liveness rule judges the waits it returns (`InputVerificationService.expectationRule`).
public nonisolated struct FocusExpectationAges: Sendable {
    private var seen: [String: Entry] = [:]

    private struct Entry: Sendable {
        var key: String
        var since: ContinuousClock.Instant
    }

    public init() {}

    /// One window whose focus expectation is pending: since when (its clock), and what waits for what.
    public struct Wait: Hashable, Sendable {
        public var window: String
        public var since: ContinuousClock.Instant
        public var detail: String
    }

    /// Records the expectations of `windows` at `now` and returns each pending one with the time its clock started
    /// (the W11 liveness rule judges the wait).
    /// - Parameter holding: Windows whose keys still wait for a create's reply (`CreationInputCoordinator`, the New
    ///   Tab hold): their clock starts when the hold ends, since a slow daemon or a remote workspace may keep a
    ///   legitimate create waiting longer than the limit.
    public mutating func pending(_ windows: [InputObservation.Window], now: ContinuousClock.Instant,
                                 holding: Set<String> = []) -> [Wait] {
        var next: [String: Entry] = [:]
        var out: [Wait] = []
        for window in windows {
            guard let expectation = window.model.expectation else { continue }
            // One intent's expectation keeps its clock when it is re-keyed from a surface to its tab
            // (`rekeySurfaceWait` keeps the generation and target).
            let key = "\(expectation.target) generation \(expectation.generation)"
            let since = holding.contains(window.id) ? now : seen[window.id].flatMap { $0.key == key ? $0.since : nil } ?? now
            next[window.id] = Entry(key: key, since: since)
            out.append(Wait(window: window.id, since: since,
                            detail: "focus on \(expectation.key) (\(expectation.target)); the keys go to \(window.model.resolved.kind)"))
        }
        seen = next
        return out
    }
}
