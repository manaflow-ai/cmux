import Foundation

struct MobileWorkspaceDiffActiveRequest {
    let id: UUID
    let task: Task<MobileHostRPCResult, Never>
}
