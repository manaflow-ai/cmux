import AppKit
import Bonsplit
import CmuxWorkspaces
import Foundation

/// Cmd+D / Cmd+T from a pane that projects a cloud resource create the new terminal ON
/// that machine — in the same cmux-tui workspace — instead of a local shell. Same rule
/// as the remote tmux mirror: a "split" next to a remote pane means "another terminal
/// where that pane lives". The new terminal is created through the machine's provider
/// (`workspace <ws> run`) and projected back into this workspace at the requested spot,
/// so the sidebar, the socket, and the shortcut agree on what exists.
/// Installs the temporary panel used while a Cloud terminal split is materialized.
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
    /// Returns false when the source panel is not a cloud projection (create locally).
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
            near: resource, sourcePanelID: panelID,
            destination: .split(workspaceID: id, paneID: paneID.id.uuidString, direction: direction),
            preferredRemoteWorkspaceID: SurfaceCatalog.shared.projection(forPanel: panelID)?.remoteWorkspaceID,
            focus: focus
        )
    }

    /// Routes a bonsplit UI split (the pane-divider split button) whose source pane
    /// projects a cloud resource: the already-created empty pane receives the machine's
    /// new terminal as its first tab. Returns false when the source is not cloud-anchored.
    func routeCloudPaneUISplit(from sourcePanelID: UUID, into newPane: PaneID, orientation: SplitOrientation) -> Bool {
        guard let resource = cloudProjectedResource(forPanel: sourcePanelID) else { return false }
        return routeCloudPaneTerminalCreate(
            near: resource, sourcePanelID: sourcePanelID,
            destination: .tab(workspaceID: id, paneID: newPane.id.uuidString, index: nil),
            preferredRemoteWorkspaceID: SurfaceCatalog.shared.projection(forPanel: sourcePanelID)?.remoteWorkspaceID,
            focus: true,
            splitDirection: orientation == .horizontal ? .right : .down,
            pendingPane: newPane
        )
    }

    /// Routes a Cmd+T-style new tab in a pane whose selected tab projects a cloud
    /// resource to that machine. Returns false when the pane is not cloud-anchored.
    func routeCloudPaneTerminalTab(inPane paneID: PaneID, focus: Bool) -> Bool {
        guard let resource = cloudProjectedResource(inPane: paneID) else { return false }
        return routeCloudPaneTerminalCreate(
            near: resource, sourcePanelID: bonsplitController.selectedTab(inPane: paneID).flatMap { panelIdFromSurfaceId($0.id) },
            destination: .tab(workspaceID: id, paneID: paneID.id.uuidString, index: nil),
            preferredRemoteWorkspaceID: bonsplitController.selectedTab(inPane: paneID).flatMap { panelIdFromSurfaceId($0.id) }.flatMap { SurfaceCatalog.shared.projection(forPanel: $0)?.remoteWorkspaceID },
            focus: focus
        )
    }

    /// Creates a terminal on `resource`'s machine (in the remote workspace of the
    /// anchor's first view, when it has one) and projects it at `destination`.
    /// Optimistic like the cloud tree's "New Terminal Here": the pane appears when the
    /// machine reports the terminal; a failure is announced instead of silently doing
    /// nothing, because the user's gesture otherwise looks dead.
    private func routeCloudPaneTerminalCreate(
        near resource: SurfaceResource,
        sourcePanelID: UUID?,
        destination: SurfaceDestination,
        preferredRemoteWorkspaceID: String? = nil,
        focus: Bool,
        splitDirection: SurfaceSplitDirection? = nil,
        pendingPane: PaneID? = nil
    ) -> Bool {
        let catalog = SurfaceCatalog.shared
        guard let provider = catalog.provider(for: resource.machine) else { return false }
        let remoteWorkspaceID = catalog.cloudPlacementCoordinator.creationWorkspaceID(in: id, near: resource, preferredRemoteWorkspaceID: preferredRemoteWorkspaceID)
        let machine = resource.machine
        let sourceProjection = sourcePanelID.flatMap { catalog.projection(forPanel: $0) }
        if remoteWorkspaceID == nil, sourceProjection?.remoteTabID == nil {
            Task { @MainActor in
                Self.presentCloudPaneCreationFailure(machine: machine, error: SurfaceCatalogError.ambiguousRemotePlacement(resource.id, workspaceID: ""))
            }
            return true
        }
        let pendingPanel: CloudTerminalPendingPanel?
        if let pendingPane {
            guard let pending = installCloudTerminalPendingPanel(machine: machine, in: pendingPane) else {
                // The pane may have been closed or claimed while Bonsplit was
                // delivering the split callback. Remove only an untouched pane;
                // never leave a handled Cloud request as a blank slot.
                if bonsplitController.allPaneIds.contains(pendingPane),
                   bonsplitController.tabs(inPane: pendingPane).isEmpty {
                    _ = bonsplitController.closePane(pendingPane)
                }
                return true
            }
            pendingPanel = pending
        } else {
            pendingPanel = nil
        }

        let scope = catalog.beginProjectionMutation(for: [resource.id])
        var projectionMutationEnded = false
        let endProjectionMutation: @MainActor () -> Void = {
            guard !projectionMutationEnded else { return }
            projectionMutationEnded = true
            catalog.endProjectionMutation(scope)
        }
        let create: CloudTerminalCreationCoordinator.Create = {
            do {
                let source = sourceProjection
                let direction: SurfaceSplitDirection?
                if case .split(_, _, let requested) = destination { direction = requested }
                else { direction = splitDirection }
                if let sourceTabID = source?.remoteTabID,
                   let layoutProvider = provider as? any SurfaceLayoutTerminalCreating {
                    return try await layoutProvider.createTerminal(
                        nearTabID: sourceTabID,
                        splitDirection: direction
                    )
                }
                let workingDirectory = await provider.currentWorkingDirectory(of: resource)
                return try await provider.createTerminal(
                    command: nil,
                    cwd: workingDirectory,
                    name: nil,
                    remoteWorkspaceID: remoteWorkspaceID
                )
            } catch {
                endProjectionMutation()
                throw error
            }
        }
        let project: CloudTerminalCreationCoordinator.Project = { [weak self, weak pendingPanel] created in
            if let pendingPanel {
                guard let self, self.panels[pendingPanel.id] != nil else {
                    endProjectionMutation()
                    throw CancellationError()
                }
            }
            defer { endProjectionMutation() }
            return try await catalog.project(
                created.id,
                into: destination,
                focus: focus,
                reuseExisting: true,
                remoteView: created.remoteViews?.count == 1 ? created.remoteViews?.first : nil
            )
        }
        if let pendingPanel {
            let coordinator = CloudTerminalCreationCoordinator(
                panel: pendingPanel,
                create: create,
                project: project,
                onSuccess: { [weak self, weak pendingPanel] in
                    endProjectionMutation()
                    guard let self, let pendingPanel,
                          self.panels[pendingPanel.id] != nil else { return }
                    pendingPanel.onCancel = nil
                    pendingPanel.onRetry = nil
                    _ = self.closePanel(pendingPanel.id, force: true)
                },
                discardProjection: { projection in
                    catalog.endProjections(panelID: projection.panelID, reason: .replaced)
                }
            )
            pendingPanel.onCancel = {
                coordinator.cancel()
                endProjectionMutation()
            }
            pendingPanel.onRetry = { coordinator.retry() }
            coordinator.start()
        } else {
            Task { @MainActor in
                defer { endProjectionMutation() }
                do {
                    let created = try await create()
                    _ = try await project(created)
                } catch {
                    Self.presentCloudPaneCreationFailure(machine: machine, error: error)
                }
            }
        }
        return true
    }

    @MainActor
    private static func presentCloudPaneCreationFailure(machine: SurfaceMachineID, error: Error) {
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
        alert.informativeText = String(
            localized: "cloudTerminal.creation.failed.detail",
            defaultValue: "The Cloud service did not accept the terminal request."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "cloudPane.newTerminalFailed.ok", defaultValue: "OK"))
        CloudErrorCopy.install(in: alert, text: "\(alert.messageText)\n\(alert.informativeText)")
        alert.runModal()
    }
}


extension Workspace {
    /// Adds a visible pending panel to an empty Bonsplit pane.
    ///
    /// Returns nil when the pane disappeared, was claimed by another action, or
    /// Bonsplit could not create the placeholder tab. In those cases the caller
    /// must not fall through to local terminal creation.
    @discardableResult
    func installCloudTerminalPendingPanel(
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
}
