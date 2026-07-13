import Foundation

extension PortScanner {
    func enqueuePanelPublication(_ panelPortsByKey: [PanelKey: [Int]]) {
        guard publicationBuffer.enqueue(panelPortsByKey: panelPortsByKey) else { return }
        schedulePublicationDrain()
    }

    func enqueueAgentPublication(_ publications: [AgentPortScanPublication]) {
        guard publicationBuffer.enqueue(agentPublications: publications) else { return }
        schedulePublicationDrain()
    }

    private func schedulePublicationDrain() {
        Task { @MainActor [weak self] in
            await self?.drainPortPublications()
        }
    }

    @MainActor
    private func drainPortPublications() async {
        while let batch = await nextPublicationBatch() {
            if let panelCallback = onPortsUpdated {
                for (key, ports) in batch.panelPortsByKey {
                    panelCallback(key.workspaceId, key.panelId, ports)
                }
            }

            let deliveredResults = Array(batch.agentPublicationsByWorkspace.values)
            guard !deliveredResults.isEmpty else { continue }
            let currentResults = publicationState.acceptCurrentAgentPublications(deliveredResults)
            let appliedResults = currentResults.filter { result in
                onAgentPortsUpdated?(result.workspaceId, result.ports) == true
            }
            let completedLifecycles = await acknowledgeAgentResults(
                deliveredResults,
                appliedWorkspaceIds: Set(appliedResults.map(\.workspaceId))
            )
            for result in completedLifecycles {
                publicationState.finishAgentLifecycle(
                    workspaceId: result.workspaceId,
                    revision: result.revision
                )
            }
        }
    }

    private func nextPublicationBatch() async -> PortScanPublicationBatch? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: publicationBuffer.takePendingBatch())
            }
        }
    }

}
