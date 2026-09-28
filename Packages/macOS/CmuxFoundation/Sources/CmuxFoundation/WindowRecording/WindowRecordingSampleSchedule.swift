internal import Foundation

/// Monotonic frame-slot arithmetic for a window recording.
///
/// The schedule is based only on elapsed time. A slow capture therefore skips
/// every slot that passed while it was busy instead of issuing back-to-back
/// frames until a successful-frame counter catches up.
public enum WindowRecordingSampleSchedule {
    /// Returns the first scheduled target at or after `now`.
    public static func nextTargetUptime(
        previousTargetUptime: Double,
        interval: Double,
        now: Double
    ) -> Double {
        guard previousTargetUptime.isFinite,
              interval.isFinite,
              interval > 0,
              now.isFinite else {
            return now
        }
        guard previousTargetUptime < now else { return previousTargetUptime }
        let missedSlots = floor((now - previousTargetUptime) / interval) + 1
        let target = previousTargetUptime + (missedSlots * interval)
        return target.isFinite ? target : now
    }
}
