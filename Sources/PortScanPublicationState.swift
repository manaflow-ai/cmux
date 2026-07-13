import Foundation

/// Main-actor lifecycle gate for queued agent port publications.
@MainActor
final class PortScanPublicationState {
    private var lastIssuedAgentRevision: UInt64 = 0
    private var activeAgentRevisionByWorkspace: [UUID: UInt64] = [:]
    private var latestAgentRequestIDByWorkspace: [UUID: UInt64] = [:]

    nonisolated init() {}

    func nextAgentRevision(for workspaceId: UUID) -> UInt64 {
        lastIssuedAgentRevision &+= 1
        activeAgentRevisionByWorkspace[workspaceId] = lastIssuedAgentRevision
        latestAgentRequestIDByWorkspace.removeValue(forKey: workspaceId)
        return lastIssuedAgentRevision
    }

    func isCurrentAgentRevision(_ revision: UInt64, workspaceId: UUID) -> Bool {
        activeAgentRevisionByWorkspace[workspaceId] == revision
    }

    func finishAgentLifecycle(workspaceId: UUID, revision: UInt64) {
        guard activeAgentRevisionByWorkspace[workspaceId] == revision else { return }
        activeAgentRevisionByWorkspace.removeValue(forKey: workspaceId)
        latestAgentRequestIDByWorkspace.removeValue(forKey: workspaceId)
    }

    func acceptCurrentAgentPublications(
        _ publications: some Sequence<AgentPortScanPublication>
    ) -> [AgentPortScanPublication] {
        publications.filter { publication in
            guard activeAgentRevisionByWorkspace[publication.workspaceId] == publication.revision else {
                return false
            }
            let latestRequestID = latestAgentRequestIDByWorkspace[publication.workspaceId, default: 0]
            guard publication.requestID >= latestRequestID else { return false }
            latestAgentRequestIDByWorkspace[publication.workspaceId] = publication.requestID
            return true
        }
    }
}
