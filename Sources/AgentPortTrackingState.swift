import Foundation

/// Queue-confined agent root identity used to delimit retained port snapshots.
struct AgentPortTrackingState {
    private var rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>] = [:]

    mutating func replaceRoots(_ roots: Set<AgentPortRootIdentity>, workspaceId: UUID) -> Bool {
        let previous = rootsByWorkspace[workspaceId]
        let next = roots.isEmpty ? nil : roots
        if let next {
            rootsByWorkspace[workspaceId] = next
        } else {
            rootsByWorkspace.removeValue(forKey: workspaceId)
        }
        return previous != next
    }

    func roots(for workspaceIds: Set<UUID>) -> [UUID: Set<AgentPortRootIdentity>] {
        rootsByWorkspace.filter { workspaceIds.contains($0.key) }
    }
}
