#if DEBUG
import Foundation

/// Per-cycle accounting captured by the recovery stress monitor.
struct MobileRecoveryStressCycleRecord: Equatable, Sendable {
    let cycle: Int
    let generation: UInt64
    let pendingFreesBefore: Int
    let startedMilliseconds: Int64
    var pendingFreesAfter: Int?
    var freeDrained: Bool
    var drainedMilliseconds: Int64?
}
#endif
