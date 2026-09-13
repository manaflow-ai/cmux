import AppKit
import Bonsplit
import Foundation

/// Cloud pane terminal creation owns the temporary tab shown while a split is materialized.
extension Workspace {
    /// The cloud resource behind a panel, when the panel projects one.
    func cloudProjectedResource(forPanel panelID: UUID) -> SurfaceResource? {
        let catalog = SurfaceCatalog.shared
        guard let projection = catalog.projection(forPanel: panelID),
              projection.workspaceID == id,
              !projection.resource.machine.isLocal else { return nil }
        return catalog.resource(forPanel: panelID)
    }

    /// The cloud resource behind the selected tab of a pane (the Cmd+T anchor).
    func cloudProjectedResource(inPane paneID: PaneID) -> SurfaceResource? {
        guard let selectedTabID = bonsplitController.selectedTab(inPane: paneID)?.id,
              let panelID = panelIdFromSurfaceId(selectedTabID) else { return nil }
        return cloudProjectedResource(forPanel: panelID)
    }

    /// Routes a Cmd+D-style split from a cloud-projected panel to its machine.
    func routeCloudPaneTerminalSplit(
        from panelID: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool
    ) -> Bool {
        guard let resource = cloudProjectedResource(forPanel: panelID),
              let paneID = paneId(forPanelId: panelID) else { return false }
        let direction: SurfaceSplitDirection = orientation == .horizontal
            ? (insertFirst ? .left : .right)
            : (insertFirst ? .up : .down)
        return routeCloudPaneTerminalCreate(
            near: resource,
            destination: .split(workspaceID: id, paneID: paneID.id.uuidString, direction: direction),
            focus: focus
        )
    }

    /// Routes a Bonsplit split whose source pane projects a Cloud resource.
    func routeCloudPaneUISplit(from sourcePanelID: UUID, into newPane: PaneID) -> Bool {
        guard let resource = cloudProjectedResource(forPanel: sourcePanelID) else { return false }
        return routeCloudPaneTerminalCreate(
            near: resource,
            destination: .tab(workspaceID: id, paneID: newPane.id.uuidString, index: nil),
            focus: true,
            pendingPane: newPane
        )
    }

    /// Routes a Cmd+T-style new tab in a pane whose selected tab projects a Cloud resource.
    func routeCloudPaneTerminalTab(inPane paneID: PaneID, focus: Bool) -> Bool {
        guard let resource = cloudProjectedResource(inPane: paneID) else { return false }
        return routeCloudPaneTerminalCreate(
            near: resource,
            destination: .tab(workspaceID: id, paneID: paneID.id.uuidString, index: nil),
            focus: focus
        )
    }

    /// Creates a remote terminal and projects it at `destination`.
    ///
    /// A UI-created split already contains a pane before this asynchronous operation starts.
    /// A temporary panel keeps that pane explicit while the link starts or recovers.
    private func routeCloudPaneTerminalCreate(
        near resource: SurfaceResource,
        destination: SurfaceDestination,
        focus: Bool,
        pendingPane: PaneID? = nil
    ) -> Bool {
        let catalog = SurfaceCatalog.shared
        let machine = resource.machine
        let pendingPanel: CloudTerminalPendingPanel?
        if let pendingPane {
            guard let pending = installCloudTerminalPendingPanel(machine: machine, in: pendingPane) else {
                // The new pane may have been closed or claimed by another action. Keep the
                // request routed to Cloud so it cannot fall through to a local shell.
                return true
            }
            pendingPanel = pending
        } else {
            pendingPanel = nil
        }
        let remoteWorkspaceID = catalog.cloudPlacementCoordinator.creationWorkspaceID(in: id, near: resource)
        let create: CloudTerminalCreationCoordinator.Create = {
            guard let provider = catalog.provider(for: machine) else {
                throw SurfaceCatalogError.noProvider(machine)
            }
            return try await provider.createTerminal(
                command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID
            )
        }
        let project: CloudTerminalCreationCoordinator.Project = { [weak self, weak pendingPanel] resource in
            if let pendingPanel {
                guard let self, self.panels[pendingPanel.id] != nil else {
                    throw CancellationError()
                }
            }
            _ = try await catalog.project(
                resource.id,
                into: destination,
                focus: focus,
                reuseExisting: true,
                remoteView: resource.remoteViews?.count == 1 ? resource.remoteViews?.first : nil
            )
        }
        if let pendingPanel {
            let coordinator = CloudTerminalCreationCoordinator(
                panel: pendingPanel,
                create: create,
                project: project,
                onSuccess: { [weak self, weak pendingPanel] in
                    guard let self, let pendingPanel,
                          self.panels[pendingPanel.id] != nil else { return }
                    pendingPanel.onCancel = nil
                    pendingPanel.onRetry = nil
                    _ = self.closePanel(pendingPanel.id, force: true)
                }
            )
            pendingPanel.onCancel = { coordinator.cancel() }
            pendingPanel.onRetry = { coordinator.retry() }
            coordinator.start()
        } else {
            Task { @MainActor in
                do {
                    let created = try await create()
                    _ = try await project(created)
                } catch {
                    self.presentCloudPaneCreationFailure(machine: machine, error: error)
                }
            }
        }
        return true
    }

    /// Inserts a visible temporary panel into a newly-created empty split pane.
    private func installCloudTerminalPendingPanel(
        machine: SurfaceMachineID,
        in pane: PaneID
    ) -> CloudTerminalPendingPanel? {
        guard bonsplitController.allPaneIds.contains(pane),
              bonsplitController.tabs(inPane: pane).isEmpty else { return nil }
        let pending = CloudTerminalPendingPanel(workspaceId: id, machine: machine)
        panels[pending.id] = pending
        panelTitles[pending.id] = pending.displayTitle
        guard let tab = bonsplitController.createTab(
            title: pending.displayTitle,
            icon: pending.displayIcon,
            kind: SurfaceKind.cloudVMLoading.rawValue,
            isDirty: false,
            isLoading: true,
            isPinned: false,
            inPane: pane
        ) else {
            panels.removeValue(forKey: pending.id)
            panelTitles.removeValue(forKey: pending.id)
            return nil
        }
        bindSurface(tab, toPanelId: pending.id)
        return pending
    }

    /// Presents an error only for operations whose destination already contains a real pane.
    @MainActor
    private func presentCloudPaneCreationFailure(machine: SurfaceMachineID, error: Error) {
        #if DEBUG
        cmuxDebugLog("cloud.pane.createFailed machine=\(machine.rawValue) error=\(String(reflecting: error))")
        #endif
        let alert = NSAlert()
        alert.messageText = String(
            format: String(
                localized: "cloudPane.newTerminalFailed.title",
                defaultValue: "Couldn’t start a terminal on %@"
            ),
            machine.rawValue
        )
        alert.informativeText = CloudMachineLink.errorText(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "cloudPane.newTerminalFailed.ok", defaultValue: "OK"))
        CloudErrorCopy.install(in: alert, text: "\(alert.messageText)\n\(alert.informativeText)")
        alert.runModal()
    }
}
