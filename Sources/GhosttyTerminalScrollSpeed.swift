import CoreGraphics

final class TerminalScrollSpeedAccumulator {
    private var pendingNonPreciseX: CGFloat = 0
    private var pendingNonPreciseY: CGFloat = 0

    func apply(x: inout CGFloat, y: inout CGFloat, precision: Bool) {
        let multiplier = CGFloat(TerminalScrollSpeedSettings.multiplier())
        guard multiplier != 1 else { return }
        if precision {
            x *= multiplier
            y *= multiplier
            return
        }
        x = Self.scaledNonPreciseHorizontalScrollDelta(rawDelta: x, multiplier: multiplier, pending: &pendingNonPreciseX)
        y = Self.scaledNonPreciseVerticalScrollDelta(rawDelta: y, multiplier: multiplier, pending: &pendingNonPreciseY)
    }

    private static func scaledNonPreciseHorizontalScrollDelta(
        rawDelta: CGFloat,
        multiplier: CGFloat,
        pending: inout CGFloat
    ) -> CGFloat {
        guard rawDelta != 0 else { return 0 }
        pending += rawDelta * multiplier
        let rounded = pending.rounded()
        guard rounded != 0 else { return 0 }
        pending -= rounded
        return rounded
    }

    private static func scaledNonPreciseVerticalScrollDelta(
        rawDelta: CGFloat,
        multiplier: CGFloat,
        pending: inout CGFloat
    ) -> CGFloat {
        guard rawDelta != 0 else { return 0 }
        // Ghostty clamps Darwin non-precise vertical ticks to at least 1
        // before applying its discrete row multiplier. Accumulate in that
        // pre-Ghostty tick unit so sub-1x values can slow ordinary wheels.
        let effectiveTicks = rawDelta > 0 ? max(rawDelta, 1) : min(rawDelta, -1)
        pending += effectiveTicks * multiplier
        let wholeTicks = pending > 0 ? floor(pending) : ceil(pending)
        guard wholeTicks != 0 else { return 0 }
        pending -= wholeTicks
        return wholeTicks
    }
}
