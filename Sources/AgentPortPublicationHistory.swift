import Foundation

/// Queue-confined acknowledged and pending agent port values used for deduplication.
struct AgentPortPublicationHistory {
    private var acknowledgedPortsByWorkspace: [UUID: [Int]] = [:]
    private var pendingPortsByWorkspace: [UUID: [Int]] = [:]

    mutating func shouldPublish(workspaceId: UUID, ports: [Int], forced: Bool) -> Bool {
        if pendingPortsByWorkspace[workspaceId] != nil {
            pendingPortsByWorkspace[workspaceId] = ports
            return true
        }
        let acknowledgedPorts = acknowledgedPortsByWorkspace[workspaceId]
        guard forced || acknowledgedPorts != ports else { return false }
        guard forced || acknowledgedPorts != nil || !ports.isEmpty else { return false }
        pendingPortsByWorkspace[workspaceId] = ports
        return true
    }

    mutating func acknowledge(workspaceId: UUID, ports: [Int]) {
        acknowledgedPortsByWorkspace[workspaceId] = ports
        pendingPortsByWorkspace.removeValue(forKey: workspaceId)
    }

    mutating func reject(workspaceId: UUID) {
        pendingPortsByWorkspace.removeValue(forKey: workspaceId)
    }

    mutating func remove(workspaceId: UUID) {
        acknowledgedPortsByWorkspace.removeValue(forKey: workspaceId)
        pendingPortsByWorkspace.removeValue(forKey: workspaceId)
    }
}
