import Foundation

/// Main-actor lifecycle gate for queued agent port publications.
@MainActor
final class PortScanPublicationState {
    private var agentRevisionByWorkspace: [UUID: UInt64] = [:]

    nonisolated init() {}

    func nextAgentRevision(for workspaceId: UUID) -> UInt64 {
        let revision = agentRevisionByWorkspace[workspaceId, default: 0] &+ 1
        agentRevisionByWorkspace[workspaceId] = revision
        return revision
    }

    func isCurrentAgentRevision(_ revision: UInt64, workspaceId: UUID) -> Bool {
        agentRevisionByWorkspace[workspaceId] == revision
    }

    func finishAgentLifecycle(workspaceId: UUID, revision: UInt64) {
        guard agentRevisionByWorkspace[workspaceId] == revision else { return }
        agentRevisionByWorkspace.removeValue(forKey: workspaceId)
    }
}
