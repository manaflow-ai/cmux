import Foundation

/// Convergence state machine for the iOS terminal "present discard" race.
///
/// On iOS the terminal renders through a local display-only libghostty surface
/// that has no renderer-side vsync: a frame is produced only when the surface
/// view asks for one, and every present passes through libghostty's
/// `setSurfaceCallback`, which DISCARDS any rendered IOSurface whose pixel size
/// no longer matches the live layer (`layer.bounds × layer.contentsScale`) at
/// present time — silently, with no feedback to the embedder, so `needsDraw` is
/// never re-armed. A frame rendered just before a layer resize therefore
/// presents at the wrong size, is dropped, and the terminal stays BLANK (or
/// freshly typed text stays invisible) until some unrelated event forces another
/// draw. iPhone makes this worse: the keyboard and composer occupy a large
/// fraction of the screen, so showing/hiding the keyboard and per-keystroke
/// composer growth resize the render layer constantly, widening the race.
///
/// The old mitigation was a blind fixed-count redraw burst after each geometry
/// change; if the burst was exhausted before a frame happened to land at a
/// stable size, the surface blanked. This type replaces that with a CONVERGENCE
/// guarantee: after a geometry change the surface view ``arm(now:)``s the
/// machine and, every display-link tick, calls ``tick(now:presented:)``. It
/// keeps requesting a (coalesced) redraw until a frame has actually PRESENTED at
/// the current render size, bounded by a wall-clock deadline so a layer that
/// never settles cannot pump the main queue forever, and held for a short
/// minimum so it cannot disarm on a transient match before the resize settles.
///
/// Pure value type with no UIKit / libghostty dependency: the surface view
/// supplies the real media-time and the presented-size probe, keeping the
/// decision logic unit-testable.
public struct TerminalGeometryConvergence: Sendable, Equatable {
    /// How long, in seconds, to keep retrying a present after a geometry change
    /// until one lands at the settled layer size. Generous enough to outlast a
    /// UIKit keyboard show/hide animation (~0.35s) plus a few settle frames,
    /// short enough that a genuinely stuck layer cannot pump the main queue
    /// indefinitely.
    public static let window: Double = 1.0

    /// Minimum time, in seconds, the loop holds before it may disarm early on a
    /// presented-match read, so it never stops mid-layout-animation on a
    /// transiently matching (but stale) size. ~0.4s outlasts the UIKit keyboard
    /// curve (~0.25–0.35s).
    public static let minimumHold: Double = 0.4

    /// Media-time when the current window was armed; 0 when disarmed.
    private var armedAt: Double = 0
    /// Media-time deadline after which the loop gives up; 0 when disarmed.
    private var deadline: Double = 0

    public init() {}

    /// Whether a convergence window is currently active.
    public var isArmed: Bool { deadline > 0 }

    /// Arm (or re-arm) the convergence window at `now` (a `CACurrentMediaTime`).
    public mutating func arm(now: Double) {
        armedAt = now
        deadline = now + Self.window
    }

    /// Cancel any active window (e.g. when rendering is suspended).
    public mutating func disarm() {
        armedAt = 0
        deadline = 0
    }

    /// The action the surface view should take for one display-link tick.
    public enum Tick: Sendable, Equatable {
        /// No window active; nothing to do.
        case idle
        /// Keep the frame pump running this tick (request a coalesced redraw)
        /// because no frame has yet presented at the current size.
        case redraw
        /// A frame has presented at the current size; the window is disarmed and
        /// no forced redraw is needed.
        case settled
        /// The deadline elapsed without a matching present; the window is
        /// disarmed. Surfaced for diagnostics (a likely persistent discard).
        case timedOut
    }

    /// Advance the machine by one display-link tick.
    ///
    /// - Parameters:
    ///   - now: The current media-time (`CACurrentMediaTime`).
    ///   - presented: Whether the renderer has presented a frame whose size
    ///     matches the current render rect — the Swift-side mirror of
    ///     libghostty's size-discard test. The surface view reads the presented
    ///     IOSurface's true pixel size for this.
    /// - Returns: The action to take; mutates state to disarm on
    ///   ``Tick/settled`` and ``Tick/timedOut``.
    public mutating func tick(now: Double, presented: Bool) -> Tick {
        guard deadline > 0 else { return .idle }
        // PRE-FIX behavior (the bug this type exists to remove): the redraw
        // burst gives up after a fixed hold, regardless of whether a frame has
        // actually presented at the settled size. When no good frame lands in
        // that window the terminal is left blank / typed text invisible.
        if now >= armedAt + Self.minimumHold {
            disarm()
            return .settled
        }
        return .redraw
    }
}
