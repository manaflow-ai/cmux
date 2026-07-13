import Foundation

/// Queue-confined coalescing buffer with at most one scheduled drain task.
struct PortScanPublicationBuffer {
    private(set) var isDrainScheduled = false
    private var pending = PortScanPublicationBatch()

    mutating func enqueue(panelPortsByKey: [PortScanner.PanelKey: [Int]]) -> Bool {
        pending.panelPortsByKey = panelPortsByKey
        guard !pending.isEmpty else { return false }
        return scheduleDrainIfNeeded()
    }

    mutating func enqueue(agentPublications: [AgentPortScanPublication]) -> Bool {
        guard !agentPublications.isEmpty else { return false }
        for publication in agentPublications {
            if let existing = pending.agentPublicationsByWorkspace[publication.workspaceId],
               !publication.isNewer(than: existing) {
                continue
            }
            pending.agentPublicationsByWorkspace[publication.workspaceId] = publication
        }
        return scheduleDrainIfNeeded()
    }

    mutating func takePendingBatch() -> PortScanPublicationBatch? {
        guard !pending.isEmpty else {
            isDrainScheduled = false
            return nil
        }
        let batch = pending
        pending = PortScanPublicationBatch()
        return batch
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
