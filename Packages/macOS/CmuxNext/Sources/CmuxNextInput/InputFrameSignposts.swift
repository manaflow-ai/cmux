public import CmuxNextInputCore
public import CmuxNextSignposts
public import Foundation

/// The older always-on interval an input latency slot also carries: `key.frame` for a key press
/// (``CmuxNextSignposts/SignpostName/keyToFrame``), `key.scroll_frame` for a scroll
/// (``CmuxNextSignposts/SignpostName/scrollToFrame``). `perf-signposts.py` and the Command-pan bench read these names.
public nonisolated enum InputFrameInterval: Hashable, Sendable {
    /// `key.frame`: `target=<terminal|view>` from the slot's target.
    case key
    /// `key.scroll_frame` with the begin's phase; its end's `target=<layout|content>` comes from the slot's target at
    /// close (the layout's when the layout took the scroll).
    case scroll(ScrollFramePhase)
}

/// Records the ``InputFrameInterval`` of the slots that carry one: begun when ``InputLatencyTracker`` opens the
/// slot, ended at the commit that closes it. The app's is ``InputFrameSignposts``; tests pass a recorder.
@MainActor
public protocol InputFrameIntervals: AnyObject {
    /// Begins the interval of the slot `token` names, for an event dispatched now.
    ///
    /// - Parameters:
    ///   - token: The slot's token.
    ///   - interval: Which interval.
    ///   - target: The slot's target when it opened.
    ///   - eventTimestamp: The event's time, seconds since boot (`NSEvent.timestamp`); 0 when it has none.
    func begin(_ token: InputLatencyToken, _ interval: InputFrameInterval, target: InputTarget, eventTimestamp: TimeInterval)

    /// Ends the interval of the slot `token` names, at the commit that closed it.
    ///
    /// - Parameters:
    ///   - token: The slot's token.
    ///   - target: The slot's target at close.
    ///   - outcome: How the commit boundary fired.
    func end(_ token: InputLatencyToken, target: InputTarget, outcome: CommitBoundary.Outcome)
}

/// The app's ``InputFrameIntervals``: the `key` signposter's `key.frame` and `key.scroll_frame` intervals, with the
/// same typed messages ``CmuxNextSignposts/KeyFrameSignpost`` and ``CmuxNextSignposts/ScrollFrameSignpost`` write.
///
/// The open intervals wait in a list reserved to the slot table's capacity (a turn holds a few), so a begin or an end
/// allocates nothing here.
@MainActor
public final class InputFrameSignposts: InputFrameIntervals {
    private struct Open {
        let token: InputLatencyToken
        let interval: SignpostInterval
        let isKey: Bool
    }

    private let signposter: Signposter
    /// Seconds since boot now (`NSEvent.timestamp`'s clock).
    private let now: @MainActor () -> TimeInterval
    private var open: ContiguousArray<Open> = []

    /// - Parameters:
    ///   - signposter: The `key` category signposter.
    ///   - now: Seconds since boot now.
    public init(signposter: Signposter = .key,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.signposter = signposter
        self.now = now
        open.reserveCapacity(InputLatencySlotTable.defaultCapacity)
    }

    public func begin(_ token: InputLatencyToken, _ interval: InputFrameInterval, target: InputTarget,
                      eventTimestamp: TimeInterval) {
        let age = Self.ageMilliseconds(eventTimestamp: eventTimestamp, now: now())
        switch interval {
        case .key:
            // As KeyFrameSignpost: no key.frame interval while the signposter is off.
            guard signposter.isEnabled else { return }
            let keyTarget: KeyFrameSignpost.Target = target == .terminal ? .terminal : .view
            open.append(Open(token: token, interval: signposter.begin(.keyToFrame, keyTarget: keyTarget, ageMilliseconds: age),
                             isKey: true))
        case let .scroll(phase):
            open.append(Open(token: token, interval: signposter.begin(.scrollToFrame, scrollPhase: phase, ageMilliseconds: age),
                             isKey: false))
        }
    }

    public func end(_ token: InputLatencyToken, target: InputTarget, outcome: CommitBoundary.Outcome) {
        guard let index = open.firstIndex(where: { $0.token == token }) else { return }
        let entry = open.remove(at: index)
        if entry.isKey {
            signposter.end(.keyToFrame, entry.interval, outcome)
        } else {
            signposter.end(.scrollToFrame, entry.interval, outcome, scrollTarget: target == .layout ? .layout : .content)
        }
    }

    /// The event's age in milliseconds when its dispatch began (never negative), -1 when it has no timestamp.
    nonisolated static func ageMilliseconds(eventTimestamp: TimeInterval, now: TimeInterval) -> Double {
        eventTimestamp > 0 ? max(0, now - eventTimestamp) * 1000 : -1
    }
}
