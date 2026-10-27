import Foundation
public import QuartzCore

/// One frame stall a ``FrameScheduler`` saw: no display frame came for ``FrameScheduler/stallTimeout``
/// while clients were active, so the clients ticked without the link.
///
/// The times are `CACurrentMediaTime` seconds (the display link's timebase). ``startedAt`` is the
/// last frame's timestamp, not the time the stall timer noticed, so a report or trace shows when
/// the frames stopped.
public struct FrameStall: Sendable, Equatable {
    /// The last display frame before the stall (or the time the clients activated, when no frame came).
    public var startedAt: CFTimeInterval
    /// When the scheduler saw the stall and ticked its clients without the link.
    public var detectedAt: CFTimeInterval

    /// - Parameters:
    ///   - startedAt: The last frame's timestamp.
    ///   - detectedAt: The time the stall was seen.
    public init(startedAt: CFTimeInterval, detectedAt: CFTimeInterval) {
        self.startedAt = startedAt
        self.detectedAt = detectedAt
    }
}

/// One rendering starvation ``RenderStarvationGuard`` saw (Chrome's `kRenderingStarved`): frame
/// clients were active on a display link that paced them and whose frames show, and its last tick
/// was more than ``RenderStarvationGuard/threshold`` and a frame old when a budget check or the late
/// tick itself saw it.
///
/// A ``FrameStall`` says the link stopped, whatever the main thread did; a starvation says the
/// frame waited for the main thread, and ``turn`` names the turn that kept it. The times are
/// `CACurrentMediaTime` seconds, as in ``FrameStall``.
public struct RenderStarvation: Sendable, Equatable {
    /// The scheduler whose frame clients waited (``FrameScheduler/name``).
    public var link: String
    /// Its last tick.
    public var lastTick: CFTimeInterval
    /// When the guard saw the starvation.
    public var detectedAt: CFTimeInterval
    /// The turn meter's top unattributed turn of those that ended after ``lastTick``; nil without a meter or when no
    /// turn had unattributed time.
    public var turn: UnattributedTurn?

    /// - Parameters:
    ///   - link: The late scheduler's name.
    ///   - lastTick: Its last tick.
    ///   - detectedAt: When the starvation was seen.
    ///   - turn: The turn to blame.
    public init(link: String, lastTick: CFTimeInterval, detectedAt: CFTimeInterval, turn: UnattributedTurn?) {
        self.link = link
        self.lastTick = lastTick
        self.detectedAt = detectedAt
        self.turn = turn
    }

    /// The `stall.render_starved` message: `link=<name> gap_ms=<ms> turn=<label> turn_ms=<ms>
    /// unattributed_ms=<ms>`, or `turn=unattributed` when no turn is known.
    public var message: String {
        let gap = "link=\(link) gap_ms=\(Self.milliseconds(seconds: detectedAt - lastTick))"
        guard let turn else { return gap + " turn=unattributed" }
        return gap + " turn=\(turn.label) turn_ms=\(Self.milliseconds(nanos: turn.durationNanos))"
            + " unattributed_ms=\(Self.milliseconds(nanos: turn.unattributedNanos))"
    }

    private static func milliseconds(seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }
    private static func milliseconds(nanos: UInt64) -> String { String(format: "%.2f", Double(nanos) / 1_000_000) }
}
