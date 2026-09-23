import Foundation

/// Bounds how often one terminal surface's render-grid frames are emitted to
/// paired phones.
///
/// Ungoverned, the mobile emission path captures a frame on every Ghostty
/// tick, so an animating TUI (a coding agent's spinner and streaming repaint)
/// ships ~27 frames/second — ~100KB/s over a relay — and a user's keystroke
/// echo queues behind that firehose. Text carries no information above
/// ~10 changes/second, so the pacer coalesces sustained repaints down to a
/// dynamic per-surface rate while keeping two invariants:
///
/// - **Echo bypass**: a frame that would carry a newer accepted-input marker
///   than the last emitted frame is never delayed. Pacing exists to protect
///   keystroke echoes; it must not tax them.
/// - **Chain safety**: pacing gates *capture*, not emission of already-diffed
///   frames. Each emitted delta still diffs against the previous emitted
///   frame, so the render-grid revision chain stays gapless and never
///   triggers the stale/replay machinery.
///
/// The period is dynamic per surface: it starts and stays at the floor
/// (90ms, ~11fps) while the transport keeps up, widens multiplicatively each
/// time the bounded per-connection queues shed (the transport's existing
/// backpressure signal, surfaced as a full-resync request), and decays back
/// toward the floor after a quiet interval. Pure state machine: the owner
/// supplies timestamps and schedules the deferred flush it is told to.
struct MobileTerminalFramePacer {
    /// What the owner must do with an update that just arrived.
    enum Decision: Equatable {
        /// Capture and emit now.
        case emit
        /// Hold; a flush is already scheduled for the returned deadline.
        case coalesce
        /// Hold and schedule a flush at the returned deadline.
        case coalesceAndSchedule(deadline: ContinuousClock.Instant)
    }

    /// Floor period: 90ms ≈ 11fps, the minimum liveness rate.
    static let floorPeriod: Duration = .milliseconds(90)
    /// Ceiling period: even a badly congested transport sees 2fps.
    static let ceilingPeriod: Duration = .milliseconds(500)
    /// Multiplier applied to the period on each transport shed event.
    static let backoffMultiplier: Double = 1.5
    /// Quiet time after which the period decays back toward the floor.
    static let recoveryInterval: Duration = .seconds(2)

    private(set) var period: Duration = MobileTerminalFramePacer.floorPeriod
    private(set) var lastEmitAt: ContinuousClock.Instant?
    private(set) var flushScheduled = false
    private(set) var lastShedAt: ContinuousClock.Instant?
    private(set) var lastEmittedInputSequence: UInt64?
    /// An update arrived inside the period and is waiting for the flush.
    private var heldFramePending = false

    mutating func updateArrived(
        now: ContinuousClock.Instant,
        acceptedInputSequence: UInt64?
    ) -> Decision {
        decayPeriodIfQuiet(now: now)
        // The accepted-input marker moved since the last emitted frame: this
        // capture carries the user's keystroke echo and is never paced.
        let echoPending = acceptedInputSequence != nil
            && acceptedInputSequence != lastEmittedInputSequence
        let due = lastEmitAt.map { now - $0 >= period } ?? true
        if due || echoPending {
            lastEmitAt = now
            if acceptedInputSequence != nil {
                lastEmittedInputSequence = acceptedInputSequence
            }
            // The emit captures the newest state, superseding any held frame.
            heldFramePending = false
            return .emit
        }
        heldFramePending = true
        if flushScheduled {
            return .coalesce
        }
        flushScheduled = true
        return .coalesceAndSchedule(deadline: (lastEmitAt ?? now) + period)
    }

    /// The scheduled flush fired. Returns whether the owner should capture
    /// and emit now (false when a bypassed emit already serviced the surface).
    mutating func flushFired(now: ContinuousClock.Instant) -> Bool {
        flushScheduled = false
        guard heldFramePending else { return false }
        heldFramePending = false
        lastEmitAt = now
        return true
    }

    /// An emission outside the pacer's control happened (theme delivery,
    /// cold-attach baseline, resync): record it so the next period is
    /// measured from it and any held frame is superseded.
    mutating func noteUnpacedEmit(
        now: ContinuousClock.Instant,
        acceptedInputSequence: UInt64?
    ) {
        lastEmitAt = now
        if acceptedInputSequence != nil {
            lastEmittedInputSequence = acceptedInputSequence
        }
        heldFramePending = false
    }

    /// The transport shed frames for this surface (bounded queue overflow):
    /// widen the period.
    mutating func transportDidShed(now: ContinuousClock.Instant) {
        lastShedAt = now
        period = min(Self.ceilingPeriod, Self.scaled(period, by: Self.backoffMultiplier))
    }

    /// Each quiet recovery interval since the last shed halves the period
    /// back toward the floor, so a transient congestion event does not tax
    /// liveness forever.
    private mutating func decayPeriodIfQuiet(now: ContinuousClock.Instant) {
        guard period > Self.floorPeriod else { return }
        guard let shed = lastShedAt else {
            period = Self.floorPeriod
            return
        }
        if now - shed >= Self.recoveryInterval {
            period = max(Self.floorPeriod, Self.scaled(period, by: 0.5))
            lastShedAt = now
        }
    }

    private static func scaled(_ duration: Duration, by factor: Double) -> Duration {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return .seconds(seconds * factor)
    }
}
