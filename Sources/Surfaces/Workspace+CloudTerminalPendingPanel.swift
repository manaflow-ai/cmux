import Bonsplit
import CmuxWorkspaces
import Foundation

/// The shared local mutation for Cloud terminal tabs, splits, and sidebar creation.
@MainActor
extension Workspace {
    /// Sidebar creation reserves a tab in the workspace selected at click time.
    @discardableResult
    func createCloudTerminal(
        on machine: SurfaceMachineID,
        remoteWorkspaceID: String?,
        catalog: SurfaceCatalog = .shared
    ) -> CloudTerminalPendingPanel? {
        beginCloudTerminalCreation(
            machine: machine, at: .workspace(id: id, placement: .tab),
            focus: true, catalog: catalog
        ) {
            guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
            return try await provider.createTerminal(
                command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID
            )
        }
    }

    @discardableResult
    func beginCloudTerminalCreation(
        machine: SurfaceMachineID,
        at destination: SurfaceDestination,
        focus: Bool,
        catalog: SurfaceCatalog = .shared,
        create: @escaping CloudTerminalCreationCoordinator.Create
    ) -> CloudTerminalPendingPanel? {
        let allowsFocus = focus && (TerminalController.currentSocketCommandFocusAllowanceStack().last ?? true)
        guard let pending = installCloudTerminalPendingPanel(machine: machine, at: destination, focus: allowsFocus) else { return nil }
        var focusToRestore: UUID?
        var endMutation: (() -> Void)?
        let finishMutation: () -> Void = {
            endMutation?()
            endMutation = nil
        }
        let coordinator = CloudTerminalCreationCoordinator(
            panel: pending,
            create: create,
            project: { [weak self, weak pending] created in
                guard let self, let pending, self.panels[pending.id] === pending,
                      let pane = self.paneId(forPanelId: pending.id) else { throw CancellationError() }
                let previousPanelID = self.focusedPanelId
                let stillFocused = allowsFocus && previousPanelID == pending.id
                    && AppDelegate.shared?.tabManagerFor(tabId: self.id)?.selectedTabId == self.id
                focusToRestore = stillFocused ? nil : previousPanelID
                let result = try await catalog.project(
                    created.id,
                    into: .tab(workspaceID: self.id, paneID: pane.id.uuidString, index: nil),
                    focus: stillFocused, reuseExisting: true, reuseInWorkspace: self.id,
                    remoteView: created.remoteViews?.count == 1 ? created.remoteViews?.first : nil
                )
                if let pendingTab = self.surfaceIdFromPanelId(pending.id),
                   let createdTab = self.surfaceIdFromPanelId(result.projection.panelID),
                   let currentPane = self.paneId(forPanelId: pending.id),
                   let index = self.bonsplitController.tabs(inPane: currentPane).firstIndex(where: { $0.id == pendingTab }) {
                    _ = self.bonsplitController.moveTab(createdTab, toPane: currentPane, atIndex: index)
                }
                // Bonsplit's reorder also selects the moved tab. Restore the
                // user's selection for background requests and rapid gestures.
                if !stillFocused, let previousPanelID, self.panels[previousPanelID] != nil {
                    self.focusPanel(previousPanelID)
                }
                return result
            },
            onSuccess: { [weak self, weak pending] projection in
                guard let self, let pending, self.panels[pending.id] === pending else { return }
                pending.onCancel = nil
                pending.onRetry = nil
                _ = self.closePanel(pending.id, force: true)
                if let focusToRestore {
                    // Retiring a tab selects its neighbor. Finish the replacement
                    // through the same focus owner as other background creations.
                    self.preserveFocusAfterNonFocusSplit(
                        preferredPanelId: focusToRestore,
                        splitPanelId: projection.panelID,
                        previousHostedView: nil
                    )
                }
            },
            discardProjection: { projection in
                catalog.endProjections(panelID: projection.panelID, reason: .replaced)
                SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
            },
            onStart: {
                let token = catalog.cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: machine)
                endMutation = { catalog.cloudWorkspaceProjectionCoordinator.endLocalMutation(token, on: machine, catalog: catalog) }
            },
            onFinish: finishMutation
        )
        pending.onCancel = { coordinator.cancel() }
        pending.onRetry = { coordinator.retry() }
        pending.onResolveResource = { try await coordinator.resource() }
        coordinator.start()
        return pending
    }

    /// Reserves the requested local position before starting any network work.
    private func installCloudTerminalPendingPanel(
        machine: SurfaceMachineID,
        at destination: SurfaceDestination,
        focus: Bool
    ) -> CloudTerminalPendingPanel? {
        guard destination.workspaceID == id, !isRetiredFromOwningTabManager else { return nil }
        let target: PaneID?
        let direction: SurfaceSplitDirection?
        switch destination {
        case .workspace(_, let placement):
            target = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
            direction = placement == .split ? .right : nil
        case .tab(_, let rawID, _):
            target = bonsplitController.allPaneIds.first { $0.id.uuidString == rawID }
            direction = nil
        case .split(_, let rawID, let requested):
            target = bonsplitController.allPaneIds.first { $0.id.uuidString == rawID }
            direction = requested
        }
        guard let target else { return nil }
        let previousPane = bonsplitController.focusedPaneId
        let previousTab = previousPane.flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
        let pending = CloudTerminalPendingPanel(workspaceId: id, machine: machine)
        panels[pending.id] = pending
        panelTitles[pending.id] = pending.displayTitle
        let installed: Bool
        if let direction {
            let tab = Bonsplit.Tab(
                title: pending.displayTitle, icon: pending.displayIcon,
                kind: SurfaceKind.cloudVMLoading.rawValue, isLoading: true
            )
            bindSurface(tab.id, toPanelId: pending.id)
            let previousProgrammaticSplit = isProgrammaticSplit
            isProgrammaticSplit = true
            installed = bonsplitController.splitPane(
                target,
                orientation: (direction == .left || direction == .right) ? .horizontal : .vertical,
                withTab: tab, insertFirst: direction == .left || direction == .up
            ) != nil
            isProgrammaticSplit = previousProgrammaticSplit
            if !installed { removeSurfaceMapping(forSurfaceId: tab.id) }
        } else if let tab = bonsplitController.createTab(
            title: pending.displayTitle, icon: pending.displayIcon,
            kind: SurfaceKind.cloudVMLoading.rawValue, isLoading: true, inPane: target
        ) {
            bindSurface(tab, toPanelId: pending.id)
            installed = true
        } else {
            installed = false
        }
        guard installed else {
            panels.removeValue(forKey: pending.id)
            panelTitles.removeValue(forKey: pending.id)
            return nil
        }
        if focus {
            focusPanel(pending.id)
        } else if let previousPane {
            bonsplitController.focusPane(previousPane)
            if let previousTab { bonsplitController.selectTab(previousTab) }
        }
        return pending
    }
}
