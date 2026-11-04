#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
import CmuxNextWakeups

/// Times each frame of a window's live resize while `debug.motion` records (FRAME OWNER REFACTOR S7; DEBUG and bench
/// builds), with `motion.frameOwner.liveResize` on or off, so a film's late frames can be split by cause. One
/// ``LiveResizeDragInput`` owns one. Per `setFrame` of the resize, ``MotionTrace`` samples (`samples` of
/// `debug.motion stop`, `t_ms` from `start`):
/// - `liveResize.wait_ms`: from the drag's event time to the start of the `setFrame` that applies it (a drag that waited
///   for a frame tick shows the wait);
/// - `liveResize.at_tick`: 1 when a frame tick gave AppKit the drag, 0 when it went in its own turn;
/// - `liveResize.lead_ms`: from the `setFrame`'s start to the first display time after it (the window's display link
///   target, only while that link ran in the last ``linkFreshness``);
/// - `liveResize.setFrame_ms`: the `setFrame`: AppKit's resize, the tree layout and what AppKit flushes inside it
///   (`lead_ms` minus this is the slack at its end);
/// - `liveResize.commit_slack_ms`: from the end of the turn's Core Animation commit (an observer one order after it)
///   to that display time; below 0 the turn's commit came after it, and what the commit carried showed a refresh late.
@MainActor
final class LiveResizeFrameProbe {
    /// A `setFrame` of the resize: when it started and the display time it can first make (nil: no recent display link).
    struct Frame {
        let start: CFTimeInterval
        let target: CFTimeInterval?
    }

    /// How old the window's last display-link frame may be for its target to place a `setFrame` on the refresh.
    static let linkFreshness: CFTimeInterval = 0.1
    /// One after Core Animation's commit observer (order 2,000,000), as ``MotionCommitProbe``'s.
    static let afterCommitOrder: CFIndex = 2_000_001

    /// The display times of the frames applied since the last commit.
    private var awaitingCommit: [CFTimeInterval] = []
    private var observer: CFRunLoopObserver?

    /// A `setFrame` of the live resize starts in `window`; nil unless `debug.motion` records. `eventTime`: the drag
    /// AppKit applies (`NSEvent.timestamp`); `atTick`: a frame tick gave it.
    func frameWillApply(in window: NSWindow, eventTime: TimeInterval?, atTick: Bool) -> Frame? {
        guard MotionTrace.isEnabled else { return nil }
        let start = CACurrentMediaTime()
        let tick = FrameScheduler.forWindow(window).lastTick
        let target = tick.flatMap { tick in tick.refreshInterval.flatMap { Self.target(after: start, frameTarget: tick.targetTimestamp, interval: $0) } }
        if let eventTime { MotionTrace.sample("liveResize.wait_ms", (start - eventTime) * 1000) }
        MotionTrace.sample("liveResize.at_tick", atTick ? 1 : 0)
        if let target { MotionTrace.sample("liveResize.lead_ms", (target - start) * 1000) }
        return Frame(start: start, target: target)
    }

    /// That `setFrame` returned: its time now, its commit's when the turn commits.
    func frameDidApply(_ frame: Frame) {
        MotionTrace.sample("liveResize.setFrame_ms", (CACurrentMediaTime() - frame.start) * 1000)
        guard let target = frame.target else { return }
        awaitingCommit.append(target)
        guard observer == nil else { return }
        // One shot: the turn's commit ends just before it; the run loop drops it after it runs.
        let observer = MainRunLoopObserver.afterCommitObserver(activities: [.beforeWaiting, .exit], repeats: false,
                                                               order: Self.afterCommitOrder) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitDidEnd() } // main-proof: added to the main run loop only
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func commitDidEnd() {
        let end = CACurrentMediaTime()
        for target in awaitingCommit { MotionTrace.sample("liveResize.commit_slack_ms", (target - end) * 1000) }
        awaitingCommit.removeAll()
        observer = nil
    }

    /// The first display time at or after `time` on a display link whose last frame shows at `frameTarget`, one refresh
    /// every `interval` seconds; nil when that frame is older than ``linkFreshness`` or `interval` is not a period. A
    /// synthesized frame (no refresh period) places nothing: the caller passes none.
    static func target(after time: CFTimeInterval, frameTarget: CFTimeInterval, interval: Double) -> CFTimeInterval? {
        guard interval > 0, interval.isFinite, time - frameTarget < linkFreshness else { return nil }
        guard time > frameTarget else { return frameTarget }
        return frameTarget + ((time - frameTarget) / interval).rounded(.up) * interval
    }
}
#endif
