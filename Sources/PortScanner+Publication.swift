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

            guard let agentCallback = onAgentPortsUpdated else { continue }
            let lifecycleResults = batch.agentPublicationsByWorkspace.values.filter { result in
                publicationState.isCurrentAgentRevision(result.revision, workspaceId: result.workspaceId)
            }
            let latestResults = await filterLatestAgentPublications(lifecycleResults)
            let currentResults = latestResults.filter { result in
                publicationState.isCurrentAgentRevision(result.revision, workspaceId: result.workspaceId)
            }
            guard !currentResults.isEmpty else { continue }
            let appliedResults = currentResults.filter { result in
                agentCallback(result.workspaceId, result.ports)
            }
            for result in currentResults where result.removesLifecycle {
                publicationState.finishAgentLifecycle(
                    workspaceId: result.workspaceId,
                    revision: result.revision
                )
            }
            let appliedWorkspaceIds = Set(appliedResults.map(\.workspaceId))
            await acknowledgeAgentResults(currentResults, appliedWorkspaceIds: appliedWorkspaceIds)
        }
    }

    private func nextPublicationBatch() async -> PortScanPublicationBatch? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: publicationBuffer.takePendingBatch())
            }
        }
    }

    private func filterLatestAgentPublications(
        _ publications: [AgentPortScanPublication]
    ) async -> [AgentPortScanPublication] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: publications.filter { publication in
                    scanCoordination.isLatestAgentResult(
                        workspaceId: publication.workspaceId,
                        requestID: publication.requestID
                    )
                })
            }
        }
    }
}
