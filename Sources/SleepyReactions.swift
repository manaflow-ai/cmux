import Foundation

/// Timestamps of recent pokes/taps that drive Sleepy Mode easter-egg reactions,
/// passed into the renderer each frame.
struct SleepyReactions {
    /// When the mascot was last poked.
    var mascotAt: Double?
    /// Consecutive rapid mascot pokes (for escalating reactions).
    var mascotPokes: Int
    /// When each pet (by index) was last poked.
    var petAt: [Int: Double]
    /// When the moon was last poked.
    var moonAt: Double?
}
