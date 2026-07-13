import Foundation

/// Queue-confined agent root identity used to delimit retained port snapshots.
struct AgentPortTrackingState {
    private var rootPIDsByWorkspace: [UUID: Set<Int>] = [:]

    mutating func replaceRootPIDs(_ rootPIDs: Set<Int>, workspaceId: UUID) -> Bool {
        let previous = rootPIDsByWorkspace[workspaceId]
        let next = rootPIDs.isEmpty ? nil : rootPIDs
        if let next {
            rootPIDsByWorkspace[workspaceId] = next
        } else {
            rootPIDsByWorkspace.removeValue(forKey: workspaceId)
        }
        return previous != next
    }
}
