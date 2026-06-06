import Foundation

struct ClosedWindowHistoryEntry: Codable {
    let windowId: UUID?
    let snapshot: SessionWindowSnapshot
    let workspaceIds: [UUID]

    init(windowId: UUID? = nil, snapshot: SessionWindowSnapshot, workspaceIds: [UUID] = []) {
        self.windowId = windowId
        self.snapshot = snapshot
        self.workspaceIds = workspaceIds
    }
}
