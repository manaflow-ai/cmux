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
/// A key's `key.frame` goes through the one ``CmuxNextSignposts/KeyFrameSignpost``: it samples secure event input into
/// the keystroke-timing gate, begins with no heap allocation and ends at its own commit observer, so ``end(_:target:outcome:)``
/// has nothing to do for a key. The open scroll intervals wait in a list reserved to the slot table's capacity (a turn
/// holds a few), so a begin or an end allocates nothing here.
@MainActor
public final class InputFrameSignposts: InputFrameIntervals {
    private struct OpenScroll {
        let token: InputLatencyToken
        let interval: SignpostInterval
    }

    private let signposter: Signposter
    /// Makes the `key.frame` signposts at the first key (the app's installs its main run-loop observer then).
    private let makeKeyFrames: @MainActor () -> KeyFrameSignpost
    private var madeKeyFrames: KeyFrameSignpost?
    /// Seconds since boot now (`NSEvent.timestamp`'s clock).
    private let now: @MainActor () -> TimeInterval
    private var open: ContiguousArray<OpenScroll> = []
    /// Gets each committed key's `key.frame` time in microseconds (``CmuxNextSignposts/KeyFrameSignpost/committedKey``).
    public var committedKey: ((_ micros: UInt64) -> Void)? {
        didSet { madeKeyFrames?.committedKey = committedKey }
    }

    /// - Parameters:
    ///   - signposter: The `key` category signposter (the scroll intervals').
    ///   - now: Seconds since boot now.
    ///   - keyFrames: Makes the `key.frame` signposts at the first key (the app's ``CmuxNextSignposts/KeyFrameSignpost``
    ///     on the main run loop by default; tests pass one they end themselves).
    public init(signposter: Signposter = .key,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                keyFrames: @escaping @MainActor () -> KeyFrameSignpost = { KeyFrameSignpost() }) {
        self.signposter = signposter
        self.now = now
        makeKeyFrames = keyFrames
        open.reserveCapacity(InputLatencySlotTable.defaultCapacity)
    }

    /// The `key.frame` signposts, made at the first call.
    private var keyFrames: KeyFrameSignpost {
        if let madeKeyFrames { return madeKeyFrames }
        let made = makeKeyFrames()
        made.committedKey = committedKey
        madeKeyFrames = made
        return made
    }

    public func begin(_ token: InputLatencyToken, _ interval: InputFrameInterval, target: InputTarget,
                      eventTimestamp: TimeInterval) {
        switch interval {
        case .key:
            keyFrames.begin(target: target == .terminal ? .terminal : .view, eventTimestamp: eventTimestamp, now: now())
        case let .scroll(phase):
            let age = Self.ageMilliseconds(eventTimestamp: eventTimestamp, now: now())
            open.append(OpenScroll(token: token, interval: signposter.begin(.scrollToFrame, scrollPhase: phase, ageMilliseconds: age)))
        }
    }

    public func end(_ token: InputLatencyToken, target: InputTarget, outcome: CommitBoundary.Outcome) {
        guard let index = open.firstIndex(where: { $0.token == token }) else { return }
        let entry = open.remove(at: index)
        signposter.end(.scrollToFrame, entry.interval, outcome, scrollTarget: target == .layout ? .layout : .content)
    }

    /// The event's age in milliseconds when its dispatch began (never negative), -1 when it has no timestamp.
    nonisolated static func ageMilliseconds(eventTimestamp: TimeInterval, now: TimeInterval) -> Double {
        eventTimestamp > 0 ? max(0, now - eventTimestamp) * 1000 : -1
    }
}
