import CCmuxScreenKit
import CoreGraphics
import Foundation

/// One finger on the screen in trackpad mode, as a laptop trackpad reads
/// it: moving moves the cursor, a tap clicks, tap then touch again and drag
/// (tap-and-a-half) drags, and a long press without moving drags too. The
/// rules are cmux-rd-core `screen_kit::trackpad`; the view feeds touches and
/// times (seconds, any one clock) and sends the actions it returns.
package struct TrackpadGesture {
    package enum Action: Equatable, Sendable {
        /// Move the cursor by the finger's travel (points) over `dt` seconds.
        case move(dx: Double, dy: Double, dt: Double)
        case press
        case release
    }

    private let handle = ScreenKitHandle(cmux_screen_trackpad_new(), free: cmux_screen_trackpad_free)

    package init() {}

    /// The button is down (a tap's window, a drag).
    package var buttonHeld: Bool { state.held }

    /// When ``advance(to:)`` next has something to do (a long press, the
    /// end of a tap's window); nil when nothing is waiting.
    package var deadline: TimeInterval? { state.deadline }

    private var state: (held: Bool, deadline: TimeInterval?) {
        var held = false, hasDeadline = false, deadline = 0.0
        cmux_screen_trackpad_state(handle.raw, &held, &hasDeadline, &deadline)
        return (held, hasDeadline ? deadline : nil)
    }

    package mutating func touchDown(at time: TimeInterval) -> [Action] {
        actions { cmux_screen_trackpad_touch_down(handle.raw, time, $0, $1) }
    }

    package mutating func touchMoved(dx: Double, dy: Double, at time: TimeInterval) -> [Action] {
        actions { cmux_screen_trackpad_touch_moved(handle.raw, dx, dy, time, $0, $1) }
    }

    package mutating func touchUp(at time: TimeInterval) -> [Action] {
        actions { cmux_screen_trackpad_touch_up(handle.raw, time, $0, $1) }
    }

    /// The touch ended without a gesture (a second finger arrived, the
    /// system took it): a held button releases.
    package mutating func cancel() -> [Action] {
        actions { cmux_screen_trackpad_cancel(handle.raw, $0, $1) }
    }

    /// Time passed: a still touch becomes a long-press drag, and a tap
    /// whose window ran out releases its click.
    package mutating func advance(to time: TimeInterval) -> [Action] {
        actions { cmux_screen_trackpad_advance(handle.raw, time, $0, $1) }
    }

    private func actions(
        _ call: (UnsafeMutablePointer<CmuxScreenTrackpadAction>, UnsafeMutablePointer<Int>) -> Int32
    ) -> [Action] {
        withUnsafeTemporaryAllocation(of: CmuxScreenTrackpadAction.self, capacity: Int(CMUX_SCREEN_TRACKPAD_MAX_ACTIONS)) { buffer in
            var count = 0
            guard let base = buffer.baseAddress, call(base, &count) == CMUX_SCREEN_OK, count > 0 else { return [] }
            return buffer.prefix(count).map { action in
                switch action.kind {
                case CMUX_SCREEN_TRACKPAD_PRESS: .press
                case CMUX_SCREEN_TRACKPAD_RELEASE: .release
                default: .move(dx: action.dx, dy: action.dy, dt: action.dt)
                }
            }
        }
    }
}

/// Pointer acceleration for trackpad mode (cmux-rd-core
/// `screen_kit::trackpad`): slow strokes move the cursor as far as the
/// finger went, fast ones up to three times further, eased in between.
package struct PointerAcceleration: Sendable {
    private let curve = cmux_screen_acceleration_default()

    package init() {}

    package func gain(speed: Double) -> Double {
        cmux_screen_acceleration_gain(curve, speed)
    }

    /// The cursor's travel in framebuffer pixels for a finger's travel in
    /// points over `dt` seconds, with `pixelsPerPoint` framebuffer pixels
    /// under one point of the view (1 / zoom scale).
    package func delta(dx: Double, dy: Double, dt: Double, pixelsPerPoint: Double) -> CGVector {
        let delta = cmux_screen_acceleration_delta(curve, dx, dy, dt, pixelsPerPoint)
        return CGVector(dx: delta.x, dy: delta.y)
    }
}

/// Makes a double tap a double click at one point (cmux-rd-core
/// `screen_kit::trackpad`): a tap soon after the last one and close to it
/// clicks exactly where that one did.
package struct ClickSnap {
    private let handle = ScreenKitHandle(cmux_screen_click_snap_new(), free: cmux_screen_click_snap_free)

    package init() {}

    /// Where a tap at `point` (at `time`) clicks; `radius` is in the point's units.
    package mutating func point(for point: CGPoint, at time: TimeInterval, radius: CGFloat) -> CGPoint {
        var out = CmuxScreenPoint()
        guard cmux_screen_click_snap_point(handle.raw, CmuxScreenPoint(point), time, radius, &out) == CMUX_SCREEN_OK else {
            return point
        }
        return CGPoint(out)
    }
}
