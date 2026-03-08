import Foundation

@MainActor
final class PanelLifecycleCoordinator {
    private var shadowState = PanelLifecycleShadowState()

    func updateMountedWorkspaceState(
        mountedWorkspaceIds: [UUID],
        retiringWorkspaceId: UUID?,
        handoffGeneration: UInt64
    ) {
        shadowState.reduce(
            .mountedWorkspaceState(
                mountedWorkspaceIds: mountedWorkspaceIds,
                retiringWorkspaceId: retiringWorkspaceId,
                handoffGeneration: handoffGeneration
            )
        )
    }

    func recordAnchorFact(
        panelId: UUID,
        workspaceId: UUID,
        panelType: PanelType,
        anchorId: UUID,
        windowNumber: Int?,
        hasSuperview: Bool,
        attachedToWindow: Bool,
        hidden: Bool,
        geometryRevision: UInt64,
        desiredVisible: Bool,
        desiredActive: Bool,
        source: String
    ) {
        shadowState.reduce(
            .anchorFact(
                PanelLifecycleAnchorFact(
                    panelId: panelId,
                    workspaceId: workspaceId,
                    panelType: panelType,
                    anchorId: anchorId,
                    windowNumber: windowNumber,
                    hasSuperview: hasSuperview,
                    attachedToWindow: attachedToWindow,
                    hidden: hidden,
                    geometryRevision: geometryRevision,
                    desiredVisible: desiredVisible,
                    desiredActive: desiredActive,
                    source: source
                )
            )
        )
    }

    func removeAnchorFact(panelId: UUID) {
        shadowState.reduce(.anchorRemoved(panelId: panelId))
    }

    func snapshot(
        workspaces: [Workspace],
        selectedWorkspaceId: UUID?,
        activeWindowNumber: Int?,
        terminalBindings: [TerminalLifecycleExecutorBindingSnapshot],
        browserBindings: [BrowserLifecycleExecutorBindingSnapshot],
        audit: PanelLifecycleExecutorAuditSnapshot?
    ) -> PanelLifecycleSnapshot {
        let records = buildRecords(
            workspaces: workspaces,
            selectedWorkspaceId: selectedWorkspaceId,
            activeWindowNumber: activeWindowNumber
        )
        let desiredRecords = records.map {
            PanelLifecycleShadowMapper.desiredRecord(from: $0, activeWindowNumber: activeWindowNumber)
        }
        let mountedWorkspaceIds = shadowState.mountedWorkspaceIds
        let retiringWorkspaceId = shadowState.retiringWorkspaceId
        let handoffGeneration = shadowState.handoffGeneration

        return PanelLifecycleSnapshot(
            selectedWorkspaceId: selectedWorkspaceId,
            retiringWorkspaceId: retiringWorkspaceId,
            mountedWorkspaceIds: mountedWorkspaceIds.sorted { $0.uuidString < $1.uuidString },
            handoffGeneration: handoffGeneration,
            activeWindowNumber: activeWindowNumber,
            counts: PanelLifecycleShadowMapper.counts(
                for: records,
                mountedWorkspaceCount: mountedWorkspaceIds.count
            ),
            desired: PanelLifecycleDesiredSnapshot(
                counts: PanelLifecycleShadowMapper.desiredCounts(for: desiredRecords),
                divergence: PanelLifecycleShadowMapper.divergenceCounts(
                    currentRecords: records,
                    desiredRecords: desiredRecords
                ),
                terminalExecutorPlan: TerminalLifecycleExecutor.makePlan(
                    currentRecords: records,
                    desiredRecords: desiredRecords,
                    currentBindings: terminalBindings
                ),
                browserExecutorPlan: BrowserLifecycleExecutor.makePlan(
                    currentRecords: records,
                    desiredRecords: desiredRecords,
                    currentBindings: browserBindings
                ),
                documentExecutorPlan: DocumentLifecycleExecutor.makePlan(
                    currentRecords: records,
                    desiredRecords: desiredRecords
                ),
                records: desiredRecords
            ),
            audit: audit,
            records: records
        )
    }

    func desiredRecord(
        for panelId: UUID,
        workspaces: [Workspace],
        selectedWorkspaceId: UUID?,
        activeWindowNumber: Int?
    ) -> PanelLifecycleDesiredRecordSnapshot? {
        buildRecords(
            workspaces: workspaces,
            selectedWorkspaceId: selectedWorkspaceId,
            activeWindowNumber: activeWindowNumber
        )
        .first(where: { $0.panelId == panelId })
        .map { PanelLifecycleShadowMapper.desiredRecord(from: $0, activeWindowNumber: activeWindowNumber) }
    }

    func isTerminalPanelReadyForWorkspaceHandoff(
        panelId: UUID,
        workspaces: [Workspace],
        selectedWorkspaceId: UUID?,
        activeWindowNumber: Int?,
        binding: TerminalLifecycleExecutorBindingSnapshot?
    ) -> Bool {
        let records = buildRecords(
            workspaces: workspaces,
            selectedWorkspaceId: selectedWorkspaceId,
            activeWindowNumber: activeWindowNumber
        )
        guard let currentRecord = records.first(where: { $0.panelId == panelId }) else {
            return false
        }
        let desiredRecord = PanelLifecycleShadowMapper.desiredRecord(
            from: currentRecord,
            activeWindowNumber: activeWindowNumber
        )
        return TerminalLifecycleExecutor.isCurrentGenerationBoundVisibleReadyForWorkspaceHandoff(
            currentRecord: currentRecord,
            desiredRecord: desiredRecord,
            binding: binding
        )
    }

    func isBrowserPanelReadyForWorkspaceHandoff(
        panelId: UUID,
        workspaces: [Workspace],
        selectedWorkspaceId: UUID?,
        activeWindowNumber: Int?,
        binding: BrowserLifecycleExecutorBindingSnapshot?
    ) -> Bool {
        let records = buildRecords(
            workspaces: workspaces,
            selectedWorkspaceId: selectedWorkspaceId,
            activeWindowNumber: activeWindowNumber
        )
        guard let currentRecord = records.first(where: { $0.panelId == panelId }) else {
            return false
        }
        let desiredRecord = PanelLifecycleShadowMapper.desiredRecord(
            from: currentRecord,
            activeWindowNumber: activeWindowNumber
        )
        return BrowserLifecycleExecutor.isCurrentGenerationBoundVisibleReadyForWorkspaceHandoff(
            currentRecord: currentRecord,
            desiredRecord: desiredRecord,
            binding: binding
        )
    }

    private func buildRecords(
        workspaces: [Workspace],
        selectedWorkspaceId: UUID?,
        activeWindowNumber: Int?
    ) -> [PanelLifecycleRecordSnapshot] {
        let mountedWorkspaceIds = shadowState.mountedWorkspaceIds
        let retiringWorkspaceId = shadowState.retiringWorkspaceId
        let handoffGeneration = shadowState.handoffGeneration
        var records: [PanelLifecycleRecordSnapshot] = []

        for workspace in workspaces {
            let mountedWorkspace = mountedWorkspaceIds.contains(workspace.id)
            let selectedWorkspace = selectedWorkspaceId == workspace.id
            let retiringWorkspace = retiringWorkspaceId == workspace.id

            var selectedPanelIds = Set<UUID>()
            for paneId in workspace.bonsplitController.allPaneIds {
                if let selectedSurfaceId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id,
                   let selectedPanelId = workspace.panelIdFromSurfaceId(selectedSurfaceId) {
                    selectedPanelIds.insert(selectedPanelId)
                }
            }

            for panel in workspace.panels.values {
                let paneId = workspace.paneId(forPanelId: panel.id)?.id
                let tabId = workspace.surfaceIdFromPanelId(panel.id)?.uuid
                let selectedInPane = selectedPanelIds.contains(panel.id)
                records.append(
                    PanelLifecycleShadowMapper.record(
                        input: PanelLifecycleShadowRecordInput(
                            panelId: panel.id,
                            workspaceId: workspace.id,
                            paneId: paneId,
                            tabId: tabId,
                            panelType: panel.panelType,
                            mountedWorkspace: mountedWorkspace,
                            selectedWorkspace: selectedWorkspace,
                            retiringWorkspace: retiringWorkspace,
                            selectedInPane: selectedInPane,
                            isFocused: workspace.focusedPanelId == panel.id,
                            anchorFact: shadowState.anchorFact(panelId: panel.id),
                            anchorGeneration: shadowState.anchorGeneration(panelId: panel.id)
                        ),
                        activeWindowNumber: activeWindowNumber,
                        handoffGeneration: handoffGeneration
                    )
                )
            }
        }

        records.sort {
            if $0.workspaceId != $1.workspaceId {
                return $0.workspaceId.uuidString < $1.workspaceId.uuidString
            }
            return $0.panelId.uuidString < $1.panelId.uuidString
        }
        return records
    }
}
