import Foundation

struct MobileWorkspaceDiffActiveRequest {
    let id: UUID
    let task: Task<Void, Never>
    var continuation: CheckedContinuation<MobileHostRPCResult, Never>?
    var isSuperseded: Bool
}
