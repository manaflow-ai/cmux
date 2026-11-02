import CoreGraphics
import Foundation

/// One finger on the screen in trackpad mode, as a laptop trackpad reads
/// it: moving moves the cursor, a tap clicks, tap then touch again and drag
/// (tap-and-a-half) drags, and a long press without moving drags too. Pure
/// state: the view feeds it touches and times (seconds, any one clock) and
/// sends the actions it returns.
///
/// A tap presses the button at once and releases it only after
/// `dragWindow`, so a second touch inside the window continues the same
/// press as a drag (no double-click arrives at the Mac). A second quick tap
/// releases, then clicks again: the Mac counts a double click.
package struct TrackpadGesture: Sendable {
    package enum Action: Equatable, Sendable {
        /// Move the cursor by the finger's travel (points) over `dt` seconds.
        case move(dx: Double, dy: Double, dt: Double)
        case press
        case release
    }

    /// Longest touch that counts as a tap.
    package var tapDuration: TimeInterval = 0.3
    /// Travel (points) before a touch moves the cursor instead of tapping.
    package var slop: Double = 8
    /// A still touch held this long starts a drag.
    package var longPressDuration: TimeInterval = 0.45
    /// After a tap, how long a new touch may start to continue it.
    package var dragWindow: TimeInterval = 0.25

    private struct Touch: Sendable {
        var start: TimeInterval
        var lastMove: TimeInterval
        var travel = 0.0
        var pending = (dx: 0.0, dy: 0.0)
        var moved = false
        /// This touch began inside a tap's drag window (the button is down).
        var afterTap = false
        /// A long press pressed the button.
        var longPressed = false
    }

    private enum State: Sendable {
        case idle
        case touching(Touch)
        /// A tap pressed the button; it releases at `until` unless a touch begins.
        case tapHeld(until: TimeInterval)
    }

    private var state = State.idle

    package init() {}

    /// The button is down (a tap's window, a drag).
    package var buttonHeld: Bool {
        switch state {
        case .idle: false
        case .tapHeld: true
        case let .touching(touch): touch.afterTap || touch.longPressed
        }
    }

    /// When ``advance(to:)`` next has something to do (a long press, the
    /// end of a tap's window); nil when nothing is waiting.
    package var deadline: TimeInterval? {
        switch state {
        case .idle: nil
        case let .tapHeld(until): until
        case let .touching(touch): touch.moved || touch.afterTap || touch.longPressed ? nil : touch.start + longPressDuration
        }
    }

    package mutating func touchDown(at time: TimeInterval) -> [Action] {
        var actions: [Action] = []
        var afterTap = false
        switch state {
        case let .tapHeld(until):
            if time <= until { afterTap = true } else { actions.append(.release) }
        case let .touching(touch) where touch.afterTap || touch.longPressed:
            actions.append(.release)
        default:
            break
        }
        state = .touching(Touch(start: time, lastMove: time, afterTap: afterTap))
        return actions
    }

    package mutating func touchMoved(dx: Double, dy: Double, at time: TimeInterval) -> [Action] {
        guard case var .touching(touch) = state else { return [] }
        defer { state = .touching(touch) }
        touch.travel += (dx * dx + dy * dy).squareRoot()
        if touch.moved {
            let dt = time - touch.lastMove
            touch.lastMove = time
            return [.move(dx: dx, dy: dy, dt: dt)]
        }
        touch.pending.dx += dx
        touch.pending.dy += dy
        guard touch.travel > slop else { return [] }
        // Past the slop: the cursor catches up with the whole stroke so far.
        touch.moved = true
        let dt = time - touch.start
        touch.lastMove = time
        return [.move(dx: touch.pending.dx, dy: touch.pending.dy, dt: dt)]
    }

    package mutating func touchUp(at time: TimeInterval) -> [Action] {
        guard case let .touching(touch) = state else { return [] }
        let isTap = !touch.moved && time - touch.start <= tapDuration
        if touch.afterTap {
            state = .idle
            // A second tap: finish the first click and click again (a double
            // click); anything else was a drag that ends here.
            return isTap ? [.release, .press, .release] : [.release]
        }
        if touch.longPressed {
            state = .idle
            return [.release]
        }
        if isTap {
            state = .tapHeld(until: time + dragWindow)
            return [.press]
        }
        state = .idle
        return []
    }

    /// The touch ended without a gesture (a second finger arrived, the
    /// system took it): a held button releases.
    package mutating func cancel() -> [Action] {
        let held = buttonHeld
        state = .idle
        return held ? [.release] : []
    }

    /// Time passed: a still touch becomes a long-press drag, and a tap
    /// whose window ran out releases its click.
    package mutating func advance(to time: TimeInterval) -> [Action] {
        switch state {
        case let .tapHeld(until) where time >= until:
            state = .idle
            return [.release]
        case var .touching(touch) where !touch.moved && !touch.afterTap && !touch.longPressed
            && time - touch.start >= longPressDuration:
            touch.longPressed = true
            state = .touching(touch)
            return [.press]
        default:
            return []
        }
    }
}

/// Pointer acceleration for trackpad mode: slow strokes move the cursor as
/// far as the finger went (precise), fast ones up to `maximumGain` times
/// further, eased in between.
package struct PointerAcceleration: Sendable {
    package var minimumGain = 1.0
    package var maximumGain = 3.0
    /// At or below this speed (points per second) the gain is the minimum.
    package var slowSpeed = 120.0
    /// At or above this speed the gain is the maximum.
    package var fastSpeed = 1400.0

    package init() {}

    package func gain(speed: Double) -> Double {
        let t = min(max((speed - slowSpeed) / (fastSpeed - slowSpeed), 0), 1)
        let eased = t * t * (3 - 2 * t)
        return minimumGain + (maximumGain - minimumGain) * eased
    }

    /// The cursor's travel in framebuffer pixels for a finger's travel in
    /// points over `dt` seconds, with `pixelsPerPoint` framebuffer pixels
    /// under one point of the view (1 / zoom scale).
    package func delta(dx: Double, dy: Double, dt: Double, pixelsPerPoint: Double) -> CGVector {
        let speed = (dx * dx + dy * dy).squareRoot() / max(dt, 1.0 / 240)
        let scale = gain(speed: speed) * pixelsPerPoint
        return CGVector(dx: dx * scale, dy: dy * scale)
    }
}

/// Makes a double tap a double click at one point: a tap soon after the
/// last one and close to it clicks exactly where that one did, so a
/// finger's wobble does not move the pointer between the two clicks.
package struct ClickSnap: Sendable {
    /// The Mac's default double-click interval.
    package var interval: TimeInterval = 0.5
    private var last: (point: CGPoint, time: TimeInterval)?

    package init() {}

    /// Where a tap at `point` (at `time`) clicks; `radius` is in the point's units.
    package mutating func point(for point: CGPoint, at time: TimeInterval, radius: CGFloat) -> CGPoint {
        if let last, time - last.time <= interval, hypot(point.x - last.point.x, point.y - last.point.y) <= radius {
            self.last = (last.point, time)
            return last.point
        }
        last = (point, time)
        return point
    }
}
