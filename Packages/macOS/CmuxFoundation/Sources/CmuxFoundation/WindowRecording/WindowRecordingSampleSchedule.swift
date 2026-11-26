internal import Foundation

/// Monotonic frame-slot arithmetic for a window recording.
///
/// The schedule is based only on elapsed time. A slow capture therefore skips
/// every slot that passed while it was busy instead of issuing back-to-back
/// frames until a successful-frame counter catches up.
///
/// A value rather than a namespace of static functions: the sampler owns one
/// schedule and moves it forward, so the current target belongs with the
/// interval it is stepped by instead of being threaded through a call.
public struct WindowRecordingSampleSchedule: Equatable, Sendable {
    /// Seconds between slots.
    public let interval: Double

    /// The slot the sampler is currently waiting for.
    public private(set) var targetUptime: Double

    public init(firstTargetUptime: Double, interval: Double) {
        self.interval = interval
        self.targetUptime = firstTargetUptime
    }

    /// Moves the target to the first slot at or after `now` and returns it.
    ///
    /// A target that has not passed yet is kept, so an on-time sampler is never
    /// pushed a slot further out.
    @discardableResult
    public mutating func target(atOrAfter now: Double) -> Double {
        guard targetUptime.isFinite, isSteppable, now.isFinite else {
            targetUptime = now
            return targetUptime
        }
        guard targetUptime < now else { return targetUptime }
        // Rounding up lands on `now` when it is itself a slot, where adding one
        // to a floor would have thrown that frame away and waited a slot more.
        let missedSlots = ((now - targetUptime) / interval).rounded(.up)
        var stepped = targetUptime + (missedSlots * interval)
        if stepped < now {
            // Only reachable when the division rounds down in binary; the
            // contract is a slot at or after `now`, not the nearest one.
            stepped += interval
        }
        targetUptime = stepped.isFinite ? stepped : now
        return targetUptime
    }

    /// Steps one slot on, once the current target has been served.
    public mutating func advanceOneSlot() {
        guard targetUptime.isFinite, isSteppable else { return }
        let stepped = targetUptime + interval
        guard stepped.isFinite else { return }
        targetUptime = stepped
    }

    private var isSteppable: Bool {
        interval.isFinite && interval > 0
    }
}
