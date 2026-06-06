import Foundation

struct ClosedWorkspaceHistoryEntry: Codable {
    let workspaceId: UUID
    let windowId: UUID?
    let workspaceIndex: Int
    let snapshot: SessionWorkspaceSnapshot
}
