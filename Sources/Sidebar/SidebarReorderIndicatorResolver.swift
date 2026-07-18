import CoreGraphics
import Foundation

/// Pure, unit-testable control math for the gesture-driven workspace reorder.
///
/// The live drag maps two inputs — the follower's vertical position and the
/// horizontal translation — to two outputs: the insertion slot and the group
/// membership the dragged row will commit with. The whole map is a MONOTONE
/// step function of a single scalar (the velocity-biased follower probe `Y`)
/// against one strictly-increasing threshold sequence, so an infinitesimal
/// input change moves at most one decision boundary and two rows can never
/// reorder in the same event. Every persistent decision sits behind a fixed
/// dead band, never sticky state that survives large motion. The slot is fed
/// to ``SidebarDropPlanner`` for pinned-tier legality; this type owns only the
/// stable numeric mapping. (Replaces the old direction-flag probe whose
/// ~38pt teleport on a sub-pixel reversal caused the "two workspaces jump at
/// once" instability.)
enum SidebarReorderIndicatorResolver {
    /// One reorder-scope item's vertical extent in list space. For a top-level
    /// group drag, a band spans the group header plus all its member rows so
    /// the whole group reads as one target.
    struct Band: Equatable {
        let id: UUID
        let minY: CGFloat
        let maxY: CGFloat

        var midY: CGFloat { (minY + maxY) / 2 }
        var height: CGFloat { max(maxY - minY, 0) }
    }

    /// Tuning constants for the control law, centralized so the live path and
    /// the tests share one source of truth.
    enum Tuning {
        /// How far inside the follower's leading edge the saturated probe sits.
        static let probeInset: CGFloat = 6
        /// Low-pass factor for the velocity estimate (0 = frozen, 1 = raw).
        static let emaAlpha: CGFloat = 0.25
        /// Velocity → bias gain before clamping to ±B.
        static let biasGain: CGFloat = 1.5
        /// HARD per-event cap on how far the bias may move, the proof that
        /// velocity-derived state can never teleport the probe.
        static let biasSlew: CGFloat = 3
        /// Half-width of the dead band around each slot threshold.
        static let slotDeadBand: CGFloat = 4
        /// Half-width of the dead band around the membership threshold.
        static let membershipDeadBand: CGFloat = 4
        /// Horizontal translation needed to force an in-place membership flip.
        static let xFlipThreshold: CGFloat = 8
    }

    /// Updates the velocity estimate and slew-limited bias, returning the probe
    /// Y. At rest the probe is the follower CENTER (the classic iOS reference);
    /// at deliberate drag speed the bias saturates so the probe sits
    /// `probeInset` inside the follower's leading edge, giving "the row touches,
    /// not the cursor" responsiveness WITHOUT any binary direction state. The
    /// bias gets there continuously through the EMA + per-event slew cap, so a
    /// jitter reversal moves the probe by at most `|dY| + biasSlew`.
    static func probe(
        followerCenter: CGFloat,
        dY: CGFloat,
        height: CGFloat,
        ema: CGFloat,
        bias: CGFloat
    ) -> (probeY: CGFloat, ema: CGFloat, bias: CGFloat) {
        let newEMA = ema + Tuning.emaAlpha * (dY - ema)
        let maxBias = max(0, height / 2 - Tuning.probeInset)
        let biasTarget = min(max(Tuning.biasGain * newEMA, -maxBias), maxBias)
        let newBias = min(max(biasTarget, bias - Tuning.biasSlew), bias + Tuning.biasSlew)
        return (followerCenter + newBias, newEMA, newBias)
    }

    /// Schmitt-clamped staircase slot. `midYs` is the strictly-increasing
    /// sequence of neighbor band midpoints; the returned slot is in
    /// `0...midYs.count` ("above neighbor s", `count` = end sentinel). `lo`/`hi`
    /// are the threshold counts at the two edges of the dead band; clamping the
    /// previous slot into `[lo, hi]` means the slot only changes once `probeY`
    /// is unambiguously past a threshold (by `deadBand`), and `previous` is
    /// consulted ONLY inside a dead band, never as state surviving real motion.
    static func slot(
        probeY: CGFloat,
        midYs: [CGFloat],
        previous: Int,
        deadBand: CGFloat = Tuning.slotDeadBand
    ) -> Int {
        var lo = 0
        var hi = 0
        for m in midYs {
            if m + deadBand < probeY { lo += 1 }
            if m - deadBand < probeY { hi += 1 }
        }
        return min(max(previous, lo), hi)
    }

    /// Schmitt membership bit at a boundary slot. `threshold` is the midpoint of
    /// the physical gap the slot occupies; the bit only flips once `probeY` is
    /// past it by `deadBand`. `candidateFromAbove` is true when the candidate
    /// group is donated by the row ABOVE the slot (the common case at a group's
    /// bottom edge); false when donated from below (a slot directly above a
    /// group's first member).
    static func membershipIn(
        probeY: CGFloat,
        threshold: CGFloat,
        candidateFromAbove: Bool,
        currentlyIn: Bool,
        deadBand: CGFloat = Tuning.membershipDeadBand
    ) -> Bool {
        if candidateFromAbove {
            return currentlyIn ? probeY <= threshold + deadBand : probeY <= threshold - deadBand
        }
        return currentlyIn ? probeY >= threshold - deadBand : probeY >= threshold + deadBand
    }
}
