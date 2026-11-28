import Foundation

/// A timeout converted safely to the millisecond representation used by kqueue.
struct SudoKeventTimeout: Sendable {
    let milliseconds: Int

    /// Converts seconds without trapping on non-finite or oversized values.
    init(seconds: TimeInterval) {
        guard seconds > 0 else {
            milliseconds = 1
            return
        }
        guard seconds.isFinite else {
            milliseconds = Int.max
            return
        }
        let maximumSeconds = TimeInterval(Int.max / 1_000)
        guard seconds < maximumSeconds else {
            milliseconds = Int.max
            return
        }
        milliseconds = max(1, Int(ceil(seconds * 1_000)))
    }
}
