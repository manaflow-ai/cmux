import Foundation

struct MobileWorkspaceDiffPendingRequest {
    let id: UUID
    let operation: @Sendable () async -> MobileHostRPCResult
    let continuation: CheckedContinuation<MobileHostRPCResult, Never>
}
