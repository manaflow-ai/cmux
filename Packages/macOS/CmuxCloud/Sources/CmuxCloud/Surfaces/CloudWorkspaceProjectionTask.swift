import Foundation

/// Identity fences a cancelled worker's cleanup from a replacement worker.
@MainActor
public struct CloudWorkspaceProjectionTask {
    public init(
        id: UUID,
        task: Task<Void, Never>
    ) {
        self.id = id
        self.task = task
    }

    public let id: UUID
    public let task: Task<Void, Never>
}
