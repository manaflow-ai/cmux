import Foundation

/// Queue-confined acknowledgement history used for agent-port deduplication.
struct AgentPortPublicationHistory {
    private var acknowledgedPortsByWorkspace: [UUID: [Int]] = [:]
    private var pendingRequestIDByWorkspace: [UUID: UInt64] = [:]

    mutating func shouldPublish(
        workspaceId: UUID,
        ports: [Int],
        requestID: UInt64,
        forced: Bool
    ) -> Bool {
        if let pendingRequestID = pendingRequestIDByWorkspace[workspaceId] {
            pendingRequestIDByWorkspace[workspaceId] = max(pendingRequestID, requestID)
            return true
        }
        let acknowledgedPorts = acknowledgedPortsByWorkspace[workspaceId]
        guard forced || acknowledgedPorts != ports else { return false }
        guard forced || acknowledgedPorts != nil || !ports.isEmpty else { return false }
        pendingRequestIDByWorkspace[workspaceId] = requestID
        return true
    }

    mutating func acknowledge(workspaceId: UUID, ports: [Int], requestID: UInt64) {
        acknowledgedPortsByWorkspace[workspaceId] = ports
        if let pendingRequestID = pendingRequestIDByWorkspace[workspaceId],
           pendingRequestID <= requestID {
            pendingRequestIDByWorkspace.removeValue(forKey: workspaceId)
        }
    }

    mutating func reject(workspaceId: UUID, requestID: UInt64) {
        if let pendingRequestID = pendingRequestIDByWorkspace[workspaceId],
           pendingRequestID <= requestID {
            pendingRequestIDByWorkspace.removeValue(forKey: workspaceId)
        }
    }

    mutating func remove(workspaceId: UUID) {
        acknowledgedPortsByWorkspace.removeValue(forKey: workspaceId)
        pendingRequestIDByWorkspace.removeValue(forKey: workspaceId)
    }
}
