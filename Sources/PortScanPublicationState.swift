import Foundation

/// Main-actor lifecycle gate for queue-ordered panel and agent port publications.
@MainActor
final class PortScanPublicationState {
    private var lastIssuedPanelRevision: UInt64 = 0
    private var activePanelLifecycleByKey: [PortScanner.PanelKey: (ttyName: String, revision: UInt64)] = [:]
    private var lastIssuedAgentRevision: UInt64 = 0
    private var activeAgentRevisionByWorkspace: [UUID: UInt64] = [:]

    nonisolated init() {}

    func replacePanelLifecycle(key: PortScanner.PanelKey, ttyName: String) -> UInt64? {
        guard activePanelLifecycleByKey[key]?.ttyName != ttyName else { return nil }
        lastIssuedPanelRevision &+= 1
        activePanelLifecycleByKey[key] = (ttyName, lastIssuedPanelRevision)
        return lastIssuedPanelRevision
    }

    func invalidatePanelLifecycle(for key: PortScanner.PanelKey) {
        lastIssuedPanelRevision &+= 1
        activePanelLifecycleByKey.removeValue(forKey: key)
    }

    func isCurrentPanelRevision(_ revision: UInt64, key: PortScanner.PanelKey) -> Bool {
        activePanelLifecycleByKey[key]?.revision == revision
    }

    func acceptCurrentPanelPublications(
        _ publications: some Sequence<PanelPortScanPublication>
    ) -> [PanelPortScanPublication] {
        publications.filter { isCurrentPanelRevision($0.revision, key: $0.key) }
    }

    func nextAgentRevision(for workspaceId: UUID) -> UInt64 {
        lastIssuedAgentRevision &+= 1
        activeAgentRevisionByWorkspace[workspaceId] = lastIssuedAgentRevision
        return lastIssuedAgentRevision
    }

    func invalidateAgentLifecycle(for workspaceId: UUID) -> UInt64 {
        lastIssuedAgentRevision &+= 1
        activeAgentRevisionByWorkspace.removeValue(forKey: workspaceId)
        return lastIssuedAgentRevision
    }

    func isCurrentAgentRevision(_ revision: UInt64, workspaceId: UUID) -> Bool {
        activeAgentRevisionByWorkspace[workspaceId] == revision
    }

    func finishAgentLifecycle(workspaceId: UUID, revision: UInt64) {
        guard activeAgentRevisionByWorkspace[workspaceId] == revision else { return }
        activeAgentRevisionByWorkspace.removeValue(forKey: workspaceId)
    }

    func acceptCurrentAgentPublications(
        _ publications: some Sequence<AgentPortScanPublication>
    ) -> [AgentPortScanPublication] {
        publications.filter {
            activeAgentRevisionByWorkspace[$0.workspaceId] == $0.revision
        }
    }
}
