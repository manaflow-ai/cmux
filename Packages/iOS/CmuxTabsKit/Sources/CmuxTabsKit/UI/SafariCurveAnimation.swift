#if os(iOS)
import os
import SwiftUI

/// Replays a `SafariCurve` as a SwiftUI animation (the property follows
/// Safari's own per-frame progress instead of a fitted spring).
struct SafariCurveAnimation: CustomAnimation {
    let curve: SafariCurve
    /// Seconds the curve is advanced by, for a motion whose trigger reaches
    /// us later than Safari's (the slow release: one frame, measured).
    var lead: Double = 0
    /// A cue (`SafariCurveCue`) fired on the animation's first frame, which
    /// holds still (its owner times a change against the motion: the tab
    /// count, the frame before it, as in Safari).
    var cue: Int = 0

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        // The first frame on screen shows one 60 Hz frame of the curve,
        // however long the frame that made the change took: a close that
        // rebuilt the grid drew its first reflow frame two frames in (a 34 pt
        // jump). Any gap over one frame between the first calls is taken
        // out of the curve's clock.
        let first = context.state[ClockKey.self] == nil
        var clock = context.state[ClockKey.self] ?? Clock(shift: cue != 0 ? time : max(0, time - 1.0 / 60), last: time, calls: 0)
        // A cued curve holds its first frame and fires its cue there, from a
        // position (a pair), not from a fading or scaling value, which starts
        // frames earlier. The cue's owner times its change from it.
        if first, cue != 0, !(V.self == Double.self || V.self == CGFloat.self) {
            let cue = self.cue
            if Thread.isMainThread {
                MainActor.assumeIsolated { SafariCurveCue.fire(cue) }
            } else {
                DispatchQueue.main.async { SafariCurveCue.fire(cue) }
            }
        }
        if clock.calls > 0, clock.calls < 3, time - clock.last > 1.5 / 60 {
            clock.shift += time - clock.last - 1.0 / 60
        }
        // A cued curve also holds until a frame that shows its owner's change
        // (`SafariCurveCue.markApplied`) has been drawn, so the change is on
        // screen the frame before the first move however the frames fall
        // (the demo's grid draws at 30-40 Hz there, and its count and first
        // move had landed in the same frame). At most `maxHeldCalls`.
        if cue != 0, !clock.released, clock.calls > 0 {
            if SafariCurveCue.isApplied(cue) || clock.calls >= Self.maxHeldCalls {
                clock.released = true
            }
            clock.shift = time
        }
        clock.last = time
        clock.calls += 1
        context.state[ClockKey.self] = clock
        let t = time - clock.shift + lead
        guard t < curve.duration else { return nil }
        return value.scaled(by: curve.value(at: t))
    }

    static let maxHeldCalls = 4

    private struct Clock {
        var shift: Double
        var last: Double
        var calls: Int
        var released = false
    }

    private struct ClockKey: AnimationStateKey {
        static var defaultValue: Clock? { nil }
    }
}

extension Animation {
    static func safari(_ curve: SafariCurve, lead: Double = 0, cue: Int = 0) -> Animation {
        Animation(SafariCurveAnimation(curve: curve, lead: lead, cue: cue))
    }
}

/// One-shot callbacks a `SafariCurveAnimation` fires on its first frame
/// (`cue`), on the frame clock that draws the curve rather than on a
/// separate schedule.
@MainActor
final class SafariCurveCue {
    private static var handlers: [Int: () -> Void] = [:]
    private static var next = 0

    /// Registers `handler` and returns its cue (never 0).
    static func register(_ handler: @escaping () -> Void) -> Int {
        next += 1
        handlers[next] = handler
        return next
    }

    /// Runs and forgets the cue's handler (once, whichever value fires first).
    static func fire(_ cue: Int) {
        handlers.removeValue(forKey: cue)?()
    }

    /// Cues whose owner has made its change (the curve holds until a frame
    /// showing it has been drawn). Every animated value of the curve reads
    /// it, so it is kept (one integer per close).
    private nonisolated static let applied = OSAllocatedUnfairLock(initialState: Set<Int>())
    static func markApplied(_ cue: Int) { applied.withLock { _ = $0.insert(cue) } }
    nonisolated static func isApplied(_ cue: Int) -> Bool { applied.withLock { $0.contains(cue) } }
}
#endif
