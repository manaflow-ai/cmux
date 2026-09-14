import Bonsplit
import CmuxWorkspaces
import Foundation

/// Routes terminal creation gestures through one optimistic Cloud pane operation.
@MainActor
extension Workspace {
    func cloudProjectedResource(forPanel panelID: UUID, catalog: SurfaceCatalog = .shared) -> SurfaceResource? {
        guard let projection = catalog.projection(forPanel: panelID),
              projection.workspaceID == id,
              !projection.resource.machine.isLocal else { return nil }
        return catalog.resource(forPanel: panelID)
    }

    func cloudProjectedResource(inPane paneID: PaneID) -> SurfaceResource? {
        guard let selectedTabID = bonsplitController.selectedTab(inPane: paneID)?.id,
              let panelID = panelIdFromSurfaceId(selectedTabID) else { return nil }
        return cloudProjectedResource(forPanel: panelID)
    }

    func routeCloudPaneTerminalSplit(
        from panelID: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool
    ) -> Bool {
        guard let paneID = paneId(forPanelId: panelID) else { return false }
        let direction: SurfaceSplitDirection = orientation == .horizontal
            ? (insertFirst ? .left : .right)
            : (insertFirst ? .up : .down)
        return routeCloudPaneTerminalCreate(
            from: panelID,
            destination: .split(workspaceID: id, paneID: paneID.id.uuidString, direction: direction),
            focus: focus, splitDirection: direction
        )
    }

    func routeCloudPaneUISplit(from sourcePanelID: UUID, into newPane: PaneID, orientation: SplitOrientation) -> Bool {
        routeCloudPaneTerminalCreate(
            from: sourcePanelID,
            destination: .tab(workspaceID: id, paneID: newPane.id.uuidString, index: nil),
            focus: true, splitDirection: orientation == .horizontal ? .right : .down
        )
    }

    func routeCloudPaneTerminalTab(inPane paneID: PaneID, focus: Bool) -> Bool {
        guard let selected = bonsplitController.selectedTab(inPane: paneID),
              let panelID = panelIdFromSurfaceId(selected.id) else { return false }
        return routeCloudPaneTerminalCreate(
            from: panelID,
            destination: .tab(workspaceID: id, paneID: paneID.id.uuidString, index: nil),
            focus: focus, splitDirection: nil
        )
    }

    /// Pending anchors retain their request's resolver, so rapid gestures reserve
    /// their own destinations immediately and wait for the exact remote parent tab.
    private func routeCloudPaneTerminalCreate(
        from sourcePanelID: UUID,
        destination: SurfaceDestination,
        focus: Bool,
        splitDirection: SurfaceSplitDirection?
    ) -> Bool {
        let catalog = SurfaceCatalog.shared
        let resource = cloudProjectedResource(forPanel: sourcePanelID)
        let pendingSource = panels[sourcePanelID] as? CloudTerminalPendingPanel
        guard let machine = resource?.machine ?? pendingSource?.machine else { return false }
        let resolvePending = pendingSource?.onResolveResource
        let projection = catalog.projection(forPanel: sourcePanelID)
        let pending = beginCloudTerminalCreation(machine: machine, at: destination, focus: focus) { [weak self] in
            guard let self else { throw CancellationError() }
            let anchor: SurfaceResource
            if let resource { anchor = resource }
            else if let resolvePending { anchor = try await resolvePending() }
            else { throw CancellationError() }
            try Task.checkCancellation()
            guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
            let remoteView = anchor.remoteViews?.count == 1 ? anchor.remoteViews?.first : nil
            let remoteWorkspaceID = catalog.cloudPlacementCoordinator.creationWorkspaceID(
                in: self.id, near: anchor,
                preferredRemoteWorkspaceID: projection?.remoteWorkspaceID ?? remoteView?.workspace.id
            )
            let remoteTabID = projection?.remoteTabID ?? remoteView?.tabID
            if let remoteTabID, let layoutProvider = provider as? any SurfaceLayoutTerminalCreating {
                return try await layoutProvider.createTerminal(nearTabID: remoteTabID, splitDirection: splitDirection)
            }
            guard remoteWorkspaceID != nil else {
                throw SurfaceCatalogError.ambiguousRemotePlacement(anchor.id, workspaceID: "")
            }
            let workingDirectory = await provider.currentWorkingDirectory(of: anchor)
            try Task.checkCancellation()
            return try await provider.createTerminal(
                command: nil, cwd: workingDirectory, name: nil, remoteWorkspaceID: remoteWorkspaceID
            )
        }
        if pending == nil, case .tab(_, let rawID, _) = destination,
           let pane = bonsplitController.allPaneIds.first(where: { $0.id.uuidString == rawID }),
           bonsplitController.tabs(inPane: pane).isEmpty {
            _ = bonsplitController.closePane(pane)
        }
        // A Cloud gesture never falls through to a local shell, including when its
        // destination disappeared before a placeholder could be reserved.
        return true
    }

    /// Publishes a non-modal failure card for a cloud terminal request.
    func presentCloudPaneCreationFailure(
        machine: SurfaceMachineID,
        error: Error,
        requestID: UUID,
        retry: (() -> Void)? = nil
    ) {
        #if DEBUG
        cmuxDebugLog("cloud.pane.createFailed machine=\(machine.rawValue) error=\(String(reflecting: error))")
        #endif
        cloudPaneCreationFailureStore.present(machine: machine, error: error, requestID: requestID, retry: retry)
    }
}
