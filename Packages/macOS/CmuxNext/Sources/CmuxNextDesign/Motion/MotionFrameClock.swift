public import AppKit
import CmuxNextWakeups

/// When a move made now starts its curve: at the begin-frame time of the first frame that can show it, as Chrome
/// starts an animation at the frame time of the first frame that ticks it. That frame shows the move at its start
/// (the old frame) and each frame after it one refresh more of the curve, so the first frame that moves shows
/// curve(1 refresh), however far into a refresh the change was made. A move timed from the change itself showed
/// curve(2.6 refreshes) on its first moved frame (pin films, cmux21, 120 Hz: 82.5 pt in one step).
/// The moves hold their start until then (`fillMode` backwards).
@MainActor
public struct MotionFrameClock {
    /// Media time now.
    public var now: @MainActor () -> CFTimeInterval
    /// A vsync time of the display and its refresh period (the frame grid); nil when none is known.
    public var vsync: @MainActor () -> (timestamp: CFTimeInterval, interval: Double)?
    /// The display's refresh period when no grid is known.
    public var refresh: @MainActor () -> Double

    public init(now: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() },
                vsync: @escaping @MainActor () -> (timestamp: CFTimeInterval, interval: Double)?,
                refresh: @escaping @MainActor () -> Double) {
        self.now = now
        self.vsync = vsync
        self.refresh = refresh
    }

    /// The clock of `view`'s window: its frame scheduler's last vsync, its screen's refresh period.
    public static func forView(_ view: NSView) -> MotionFrameClock {
        MotionFrameClock(vsync: { [weak view] in view.flatMap { FrameScheduler.forView($0).lastVsync } },
                         refresh: { [weak view] in view?.window?.screen?.minimumRefreshInterval ?? 1.0 / 60 })
    }

    /// The begin-frame time of the first frame after now: the next vsync on the grid. With no grid known, one refresh
    /// from now (the first frame then shows at most one refresh of the curve, never more).
    public func firstFrameBegin() -> CFTimeInterval {
        let time = now()
        if let grid = vsync(), grid.interval > 0, grid.interval.isFinite, time >= grid.timestamp {
            let frames = ((time - grid.timestamp) / grid.interval).rounded(.down) + 1
            return grid.timestamp + frames * grid.interval
        }
        let period = refresh()
        return time + (period > 0 && period.isFinite ? period : 1.0 / 60)
    }
}
