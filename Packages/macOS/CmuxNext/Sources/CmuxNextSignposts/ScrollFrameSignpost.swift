public import Foundation

/// The always-on `key.scroll_frame` interval (``SignpostName/scrollToFrame``): from the app dispatching a scroll
/// event to the end of the Core Animation commit that ends that turn (``CommitBoundary``), the scroll twin of
/// ``KeyFrameSignpost``.
///
/// Begin message: `phase=<phase> age_ms=<age>`, the event's age when its dispatch began (its wait in the event
/// queue), so a reader adds that wait to the interval: input to frame. End message: `target=<layout|content>`.
/// A layout scroll applies its move in that turn, so its commit shows it (a strip pan's second event in one display
/// frame shows at the next frame's tick instead, one presentation per frame); a scroll that went on to content may
/// show in a later frame, as a terminal key's echo does (``KeyFrameSignpost``).
///
/// It runs on every scroll event for every user, recorder attached or not (``Signposter/isEnabled`` is true in
/// every build), so the per-event cost is kept to the signpost calls: the messages are typed fields the log system
/// formats only when something reads them, and the intervals that end in one main run-loop turn wait in one list
/// that one ``CommitBoundary`` closes after that turn's commit (one run-loop observer per turn, not per event).
///
/// ```swift
/// let timing = ScrollFrameSignpost()
/// timing.begin(phase: .changed, eventTimestamp: event.timestamp)
/// timing.end(target: .layout) // when the dispatch ended; the interval ends after the turn's commit
/// ```
@MainActor
public final class ScrollFrameSignpost: ScrollFrameTiming {
    /// An interval whose dispatch ended, waiting for the turn's commit.
    private struct Ended {
        let interval: SignpostInterval
        let target: ScrollFrameTarget
    }

    private let signposter: Signposter
    /// Asks for the turn's commit boundary (``CommitBoundary/after(_:)``; tests fire it themselves).
    private let afterCommit: @MainActor (@escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void
    /// Seconds since boot now (the event timestamp's clock).
    private let now: @MainActor () -> TimeInterval
    /// Begun, dispatch not ended yet: innermost last.
    private var open: [SignpostInterval] = []
    /// Dispatch ended this turn, closed together after the turn's commit; the boundary is asked for when it
    /// goes from empty to one.
    private var ended: [Ended] = []

    /// A scroll-frame signposter on ``Signposter/key``, closing each turn's intervals at its ``CommitBoundary``.
    public convenience init() {
        self.init(signposter: .key, afterCommit: { CommitBoundary().after($0) }, now: { ProcessInfo.processInfo.systemUptime })
    }

    /// - Parameters:
    ///   - signposter: The `key` signposter (tests pass one with their own MetricKit mirror).
    ///   - afterCommit: Asks for the turn's commit boundary, once per turn with intervals to close.
    ///   - now: Seconds since boot now.
    init(signposter: Signposter,
         afterCommit: @escaping @MainActor (@escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void,
         now: @escaping @MainActor () -> TimeInterval) {
        self.signposter = signposter
        self.afterCommit = afterCommit
        self.now = now
    }

    /// Intervals begun whose dispatch has not ended (tests).
    var openCount: Int { open.count }
    /// Intervals whose dispatch ended, waiting for the turn's commit (tests).
    var endedCount: Int { ended.count }

    /// Begins the interval for a scroll event dispatched now.
    ///
    /// - Parameters:
    ///   - phase: Which part of a scroll the event is.
    ///   - eventTimestamp: The event's timestamp (seconds since boot, `NSEvent.timestamp`); 0 records age -1.
    public func begin(phase: ScrollFramePhase, eventTimestamp: TimeInterval) {
        open.append(signposter.begin(.scrollToFrame, scrollPhase: phase,
                                     ageMilliseconds: Self.ageMilliseconds(eventTimestamp: eventTimestamp, now: now())))
    }

    /// Ends the dispatch of the most recent interval still open; the interval ends after this turn's commit. With
    /// none open (an end the dispatch context never pairs with a begin) there is nothing to end.
    ///
    /// - Parameter target: Who took the event.
    public func end(target: ScrollFrameTarget) {
        guard let interval = open.popLast() else { return }
        ended.append(Ended(interval: interval, target: target))
        guard ended.count == 1 else { return }  // this turn's boundary is already asked for
        afterCommit { [self] outcome in closeEnded(outcome) }
    }

    /// Ends every interval waiting for the commit, with how the boundary fired.
    private func closeEnded(_ outcome: CommitBoundary.Outcome) {
        for item in ended {
            signposter.end(.scrollToFrame, item.interval, outcome, scrollTarget: item.target)
        }
        ended.removeAll(keepingCapacity: true)
    }

    /// The event's age in milliseconds when its dispatch began (never negative), -1 when it has no timestamp.
    nonisolated static func ageMilliseconds(eventTimestamp: TimeInterval, now: TimeInterval) -> Double {
        eventTimestamp > 0 ? max(0, now - eventTimestamp) * 1000 : -1
    }
}
