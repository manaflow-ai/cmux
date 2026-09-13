import Foundation

/// Identity fences a cancelled worker's cleanup from a replacement worker.
@MainActor
struct CloudWorkspaceProjectionTask {
    let id: UUID
    let task: Task<Void, Never>
}
