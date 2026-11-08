import Foundation

/// Queue-confined coalescing and delivery-order owner with at most one drain task.
///
/// Taking a batch claims its agent publications until acknowledgement. Newer
/// values coalesce behind that claim, so a value cannot become stale between
/// queue validation and its synchronous MainActor callback.
struct PortScanPublicationBuffer {
    private(set) var isDrainScheduled = false
    private var pending = PortScanPublicationBatch()
    private var claimedAgentPublicationsByWorkspace: [UUID: AgentPortScanPublication] = [:]

    mutating func enqueue(panelPublications: some Sequence<PanelPortScanPublication>) -> Bool {
        var didEnqueue = false
        for publication in panelPublications {
            if let existing = pending.panelPublicationsByKey[publication.key],
               !publication.isNewer(than: existing) {
                continue
            }
            pending.panelPublicationsByKey[publication.key] = publication
            didEnqueue = true
        }
        guard didEnqueue else { return false }
        return scheduleDrainIfNeeded()
    }

    mutating func enqueue(agentPublications: [AgentPortScanPublication]) -> Bool {
        guard !agentPublications.isEmpty else { return false }
        for publication in agentPublications {
            if let claimed = claimedAgentPublicationsByWorkspace[publication.workspaceId],
               !publication.isNewer(than: claimed) {
                continue
            }
            if let existing = pending.agentPublicationsByWorkspace[publication.workspaceId],
               !publication.isNewer(than: existing) {
                continue
            }
            pending.agentPublicationsByWorkspace[publication.workspaceId] = publication
        }
        return scheduleDrainIfNeeded()
    }

    mutating func takePendingBatch() -> PortScanPublicationBatch? {
        guard claimedAgentPublicationsByWorkspace.isEmpty else { return nil }
        guard !pending.isEmpty else {
            isDrainScheduled = false
            return nil
        }
        let batch = pending
        pending = PortScanPublicationBatch()
        claimedAgentPublicationsByWorkspace = batch.agentPublicationsByWorkspace
        return batch
    }

    mutating func completeAgentDelivery(
        _ publications: some Sequence<AgentPortScanPublication>
    ) -> [AgentPortScanPublication] {
        var completed: [AgentPortScanPublication] = []
        for publication in publications {
            guard claimedAgentPublicationsByWorkspace[publication.workspaceId] == publication else {
                continue
            }
            claimedAgentPublicationsByWorkspace.removeValue(forKey: publication.workspaceId)
            completed.append(publication)
        }
        return completed
    }

    func hasPendingAgentPublication(newerThan publication: AgentPortScanPublication) -> Bool {
        guard let pending = pending.agentPublicationsByWorkspace[publication.workspaceId] else {
            return false
        }
        return pending.isNewer(than: publication)
    }

    mutating func removeAgentWorkspace(_ workspaceId: UUID) {
        pending.agentPublicationsByWorkspace.removeValue(forKey: workspaceId)
        claimedAgentPublicationsByWorkspace.removeValue(forKey: workspaceId)
    }

    private mutating func scheduleDrainIfNeeded() -> Bool {
        guard !isDrainScheduled else { return false }
        isDrainScheduled = true
        return true
    }
}

private extension AgentPortScanPublication {
    func isNewer(than other: AgentPortScanPublication) -> Bool {
        revision > other.revision || (revision == other.revision && requestID >= other.requestID)
    }
}

private extension PanelPortScanPublication {
    func isNewer(than other: PanelPortScanPublication) -> Bool {
        revision >= other.revision
    }
}
