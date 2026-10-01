#if DEBUG
import Foundation

/// Terminal condition detected by the recovery stress monitor.
struct MobileRecoveryStressStall: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case heartbeat
        case freeDrain = "free_drain"
    }

    let kind: Kind
    let cycle: Int?
    let generation: UInt64?
    let pendingFrees: Int
    let elapsedMilliseconds: Int64

    var marker: String {
        var fields = [
            "recovery.stress.DEADLOCK",
            "kind=\(kind.rawValue)",
            "elapsedMs=\(elapsedMilliseconds)",
            "pendingFrees=\(pendingFrees)",
        ]
        if let cycle {
            fields.append("cycle=\(cycle)")
        }
        if let generation {
            fields.append("generation=\(generation)")
        }
        return fields.joined(separator: " ")
    }
}
#endif
