import Foundation

/// One shared repository scan and the RPC callers currently awaiting it.
struct MobileWorkingTreeDiffInFlightLoad {
    let id: UUID
    let task: Task<MobileWorkingTreeDiffPayload, any Error>
    var waiters: Set<UUID>
}
