import CmuxCore
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

    func deliverAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        completenessByWorkspace: [UUID: PortScanCompleteness],
        requestID: UInt64
    ) {
        guard onAgentPortsUpdated != nil else { return }
        let validatedResults = validatedAgentResults(
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions,
            completenessByWorkspace: completenessByWorkspace,
            requestID: requestID
        )
        guard !validatedResults.isEmpty else { return }
        enqueueAgentPublication(validatedResults)
    }

    func acknowledgeAgentResults(
        _ results: [AgentPortScanPublication],
        appliedWorkspaceIds: Set<UUID>
    ) async -> [AgentPortScanPublication] {
        guard !results.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                var completedLifecycles: [AgentPortScanPublication] = []
                let deliveredResults = publicationBuffer.completeAgentDelivery(results)
                for result in deliveredResults {
                    let workspaceId = result.workspaceId
                    guard agentRevisionByWorkspace[workspaceId, default: 0] == result.revision else {
                        agentPublicationHistory.reject(
                            workspaceId: workspaceId,
                            requestID: result.requestID
                        )
                        continue
                    }
                    let hasNewerPublication = publicationBuffer.hasPendingAgentPublication(
                        newerThan: result
                    )
                    guard appliedWorkspaceIds.contains(workspaceId) else {
                        agentPublicationHistory.reject(
                            workspaceId: workspaceId,
                            requestID: result.requestID
                        )
                        if !trackedAgentWorkspaces.contains(workspaceId), !hasNewerPublication {
                            forceAgentResultWorkspaces.remove(workspaceId)
                            agentPublicationHistory.remove(workspaceId: workspaceId)
                            scanCoordination.removeAgentWorkspaces([workspaceId])
                        }
                        if result.removesLifecycle, !hasNewerPublication {
                            completedLifecycles.append(result)
                        }
                        continue
                    }
                    if !hasNewerPublication {
                        forceAgentResultWorkspaces.remove(workspaceId)
                    }
                    if result.ports.isEmpty,
                       !trackedAgentWorkspaces.contains(workspaceId),
                       !hasNewerPublication {
                        agentPublicationHistory.remove(workspaceId: workspaceId)
                        scanCoordination.removeAgentWorkspaces([workspaceId])
                    } else {
                        agentPublicationHistory.acknowledge(
                            workspaceId: workspaceId,
                            ports: result.ports,
                            requestID: result.requestID
                        )
                    }
                    if result.removesLifecycle, !hasNewerPublication {
                        completedLifecycles.append(result)
                    }
                }
                continuation.resume(returning: completedLifecycles)
            }
        }
    }

    private func validatedAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        completenessByWorkspace: [UUID: PortScanCompleteness],
        requestID: UInt64
    ) -> [AgentPortScanPublication] {
        var results: [AgentPortScanPublication] = []
        let revisionMatchedWorkspaceIds = Set(workspaceIds.filter { workspaceId in
            agentRevisionByWorkspace[workspaceId, default: 0] == agentRevisions[workspaceId, default: 0]
        })
        let validWorkspaceIds = scanCoordination.newAgentWorkspaces(
            revisionMatchedWorkspaceIds,
            eligibleWorkspaceIds: trackedAgentWorkspaces.union(forceAgentResultWorkspaces),
            requestID: requestID
        )
        for workspaceId in validWorkspaceIds {
            let completeness = completenessByWorkspace[workspaceId, default: .incomplete]
            let replacementWorkspaces = agentSnapshotReplacementState.workspacesToReplace(
                from: [workspaceId],
                completeness: completeness
            )
            agentPortSnapshot.remove(keys: replacementWorkspaces)
            let scannedPorts = agentPortsByWorkspace[workspaceId].map {
                [workspaceId: Array($0)]
            } ?? [:]
            agentPortSnapshot.reconcile(
                scannedPorts: scannedPorts,
                scannedKeys: [workspaceId],
                trackedKeys: trackedAgentWorkspaces,
                completeness: completeness
            )
        }
        let stableSnapshot = agentPortSnapshot.snapshot
        for workspaceId in validWorkspaceIds {
            let expectedRevision = agentRevisions[workspaceId, default: 0]
            let ports = stableSnapshot[workspaceId] ?? []
            let shouldPublish = agentPublicationHistory.shouldPublish(
                workspaceId: workspaceId,
                ports: ports,
                requestID: requestID,
                forced: forceAgentResultWorkspaces.contains(workspaceId)
            )
            guard shouldPublish else { continue }
            results.append(AgentPortScanPublication(
                workspaceId: workspaceId,
                ports: ports,
                revision: expectedRevision,
                requestID: requestID,
                removesLifecycle: !trackedAgentWorkspaces.contains(workspaceId)
            ))
        }
        return results
    }

}
