import AppKit
import Bonsplit
import enum CmuxTerminalBackend.BackendSplitDirection

extension Workspace {
    func splitTabBarDividerDragDidBegin(_ controller: BonsplitController) {
        if terminalClientComposition.terminalBackendTopologyMutationCoordinator != nil {
            backendDividerPositionsBeforeDrag = dividerPositions(
                in: controller.treeSnapshot()
            )
        }
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(
            owner: controller,
            in: terminalResizeInteractionWindow()
        )
    }

    func splitTabBarDividerDragDidEnd(_ controller: BonsplitController) {
        TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: controller)
        guard let mutationCoordinator = terminalClientComposition
            .terminalBackendTopologyMutationCoordinator,
              let previousPositions = backendDividerPositionsBeforeDrag else {
            backendDividerPositionsBeforeDrag = nil
            return
        }
        backendDividerPositionsBeforeDrag = nil
        let requests = changedCanonicalDividerRequests(
            in: controller.treeSnapshot(),
            previousPositions: previousPositions
        )
        for request in requests {
            mutationCoordinator.requestSetSplitRatio(
                around: request.paneID,
                direction: request.direction,
                ratio: Float(request.position),
                onFailure: { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    _ = controller.setDividerPosition(
                        request.previousPosition,
                        forSplit: request.splitID,
                        fromExternal: true
                    )
                    self.didProgrammaticallyChangeSplitGeometry()
                }
            )
        }
    }

    private struct CanonicalDividerDragRequest {
        let splitID: UUID
        let paneID: UUID
        let direction: BackendSplitDirection
        let position: Double
        let previousPosition: CGFloat
    }

    private func dividerPositions(in node: ExternalTreeNode) -> [UUID: Double] {
        switch node {
        case .pane:
            return [:]
        case .split(let split):
            var positions = dividerPositions(in: split.first)
            positions.merge(dividerPositions(in: split.second)) { first, _ in first }
            if containsBackendCanonicalPanel(in: split.first),
               containsBackendCanonicalPanel(in: split.second),
               let splitID = UUID(uuidString: split.id) {
                positions[splitID] = split.dividerPosition
            }
            return positions
        }
    }

    private func changedCanonicalDividerRequests(
        in node: ExternalTreeNode,
        previousPositions: [UUID: Double]
    ) -> [CanonicalDividerDragRequest] {
        switch node {
        case .pane:
            return []
        case .split(let split):
            var requests = changedCanonicalDividerRequests(
                in: split.first,
                previousPositions: previousPositions
            )
            requests += changedCanonicalDividerRequests(
                in: split.second,
                previousPositions: previousPositions
            )
            guard containsBackendCanonicalPanel(in: split.first),
                  containsBackendCanonicalPanel(in: split.second),
                  let splitID = UUID(uuidString: split.id),
                  let previousPosition = previousPositions[splitID],
                  abs(previousPosition - split.dividerPosition) > 0.000_1,
                  let paneID = positiveEdgeCanonicalPaneID(
                    in: split.first,
                    orientation: split.orientation
                  ) else {
                return requests
            }
            requests.append(CanonicalDividerDragRequest(
                splitID: splitID,
                paneID: paneID,
                direction: split.orientation == "horizontal" ? .right : .down,
                position: split.dividerPosition,
                previousPosition: CGFloat(previousPosition)
            ))
            return requests
        }
    }

    private func positiveEdgeCanonicalPaneID(
        in node: ExternalTreeNode,
        orientation: String
    ) -> UUID? {
        switch node {
        case .pane(let pane):
            guard containsBackendCanonicalPanel(in: node) else { return nil }
            return UUID(uuidString: pane.id)
        case .split(let split):
            if split.orientation == orientation {
                return positiveEdgeCanonicalPaneID(in: split.second, orientation: orientation)
                    ?? positiveEdgeCanonicalPaneID(in: split.first, orientation: orientation)
            }
            return positiveEdgeCanonicalPaneID(in: split.first, orientation: orientation)
                ?? positiveEdgeCanonicalPaneID(in: split.second, orientation: orientation)
        }
    }

    private func containsBackendCanonicalPanel(in node: ExternalTreeNode) -> Bool {
        switch node {
        case .pane(let pane):
            guard let paneUUID = UUID(uuidString: pane.id) else { return false }
            let paneID = PaneID(id: paneUUID)
            return bonsplitController.tabs(inPane: paneID).contains { tab in
                guard let panelID = panelIdFromSurfaceId(tab.id) else { return false }
                return isBackendCanonicalPanel(panelID)
            }
        case .split(let split):
            return containsBackendCanonicalPanel(in: split.first)
                || containsBackendCanonicalPanel(in: split.second)
        }
    }

    private func terminalResizeInteractionWindow() -> NSWindow? {
        if let eventWindow = NSApp.currentEvent?.window { return eventWindow }
        return panels.values.lazy.compactMap { panel in
            (panel as? TerminalPanel)?.hostedView.window
        }.first
    }
}

@MainActor
extension Workspace {
    func rememberBackendCanonicalTabPlacementBaseline() {
        guard terminalClientComposition.terminalBackendTopologyMutationCoordinator != nil else {
            return
        }
        backendCanonicalPanelOrderByPane = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneID in
                let panelIDs = bonsplitController.tabs(inPane: paneID).compactMap {
                    panelIdFromSurfaceId($0.id).flatMap { panelID in
                        isBackendCanonicalPanel(panelID) ? panelID : nil
                    }
                }
                return (paneID.id, panelIDs)
            }
        )
    }

    func handleBackendTabReorder(
        in pane: PaneID,
        orderedTabIDs: [TabID]
    ) -> Bool {
        guard let mutationCoordinator = terminalClientComposition
            .terminalBackendTopologyMutationCoordinator,
              !isApplyingCanonicalTopologyProjection,
              !isRollingBackBackendOptimisticTabMutation else {
            return false
        }
        let canonicalPanelIDs = orderedTabIDs.compactMap { tabID -> UUID? in
            guard let panelID = panelIdFromSurfaceId(tabID),
                  isBackendCanonicalPanel(panelID) else {
                return nil
            }
            return panelID
        }
        guard !canonicalPanelIDs.isEmpty else { return false }
        if canonicalPanelIDs == backendCanonicalPanelOrderByPane[pane.id] {
            // Only a client-native overlay moved. Its local order is already
            // committed by Bonsplit and cmuxd has no mutation to perform.
            return true
        }
        guard !backendOptimisticTabMutationInFlight else {
            restoreBackendCanonicalTabPlacementBaseline()
            mutationCoordinator.reportFailure(for: .reorderTab)
            return true
        }

        backendOptimisticTabMutationInFlight = true
        mutationCoordinator.requestReorderTabs(
            in: pane.id,
            surfaceIDs: canonicalPanelIDs,
            onProjected: { [weak self] _ in
                self?.backendOptimisticTabMutationInFlight = false
            },
            onFailure: { [weak self] in
                guard let self else { return }
                self.backendOptimisticTabMutationInFlight = false
                self.restoreBackendCanonicalTabPlacementBaseline()
            }
        )
        return true
    }

    func handleBackendTabMove(
        _ tab: Bonsplit.Tab,
        from source: PaneID,
        to destination: PaneID
    ) -> Bool {
        guard let mutationCoordinator = terminalClientComposition
            .terminalBackendTopologyMutationCoordinator,
              !isApplyingCanonicalTopologyProjection,
              !isRollingBackBackendOptimisticTabMutation,
              !isRemoteTmuxMirror,
              let panelID = panelIdFromSurfaceId(tab.id),
              isBackendCanonicalPanel(panelID) else {
            return false
        }
        guard !backendOptimisticTabMutationInFlight else {
            restoreBackendCanonicalTabPlacementBaseline()
            mutationCoordinator.reportFailure(for: .moveTab)
            return true
        }
        let destinationCanonicalOrder = bonsplitController.tabs(inPane: destination)
            .compactMap { tab -> UUID? in
                guard let candidate = panelIdFromSurfaceId(tab.id),
                      isBackendCanonicalPanel(candidate) else {
                    return nil
                }
                return candidate
            }
        guard let destinationIndex = destinationCanonicalOrder.firstIndex(of: panelID) else {
            restoreBackendCanonicalTabPlacementBaseline()
            return true
        }

        backendOptimisticTabMutationInFlight = true
        mutationCoordinator.requestMoveTab(
            panelID,
            to: destination.id,
            index: destinationIndex,
            onProjected: { [weak self] _ in
                self?.backendOptimisticTabMutationInFlight = false
            },
            onFailure: { [weak self] in
                guard let self else { return }
                self.backendOptimisticTabMutationInFlight = false
                self.restoreBackendCanonicalTabPlacementBaseline()
            }
        )
        _ = source
        return true
    }

    private func restoreBackendCanonicalTabPlacementBaseline() {
        guard !backendCanonicalPanelOrderByPane.isEmpty else { return }
        isRollingBackBackendOptimisticTabMutation = true
        defer { isRollingBackBackendOptimisticTabMutation = false }

        for paneID in bonsplitController.allPaneIds {
            guard let expectedPanelIDs = backendCanonicalPanelOrderByPane[paneID.id] else {
                continue
            }
            for (index, panelID) in expectedPanelIDs.enumerated() {
                guard let tabID = surfaceIdFromPanelId(panelID) else { continue }
                if paneId(forPanelId: panelID) != paneID {
                    _ = bonsplitController.moveTab(
                        tabID,
                        toPane: paneID,
                        atIndex: index
                    )
                }
                _ = bonsplitController.reorderTab(tabID, toIndex: index)
            }
        }
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
    }
}
