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
///
/// Every route is optimistic: the pane is reserved at the requested spot first
/// (`Workspace+CloudTerminalReservation`), the machine creates the terminal behind it,
/// and the attachment adopts the pane when it resolves. Nothing "starting" is ever shown
/// as a separate surface; a slow create shows the pane's own connecting card after the
/// same grace a reconnect uses, and a failure is explained inside the pane with Retry.
@MainActor
extension Workspace {
    /// The pane that initiated the request owns its error, regardless of later
    /// focus changes. A hidden source tab must not cover the tab replacing it.
    var cloudPaneCreationFailureSourceView: NSView? {
        guard let panelID = cloudPaneCreationFailureStore.failure?.sourcePanelID,
              let paneID = paneId(forPanelId: panelID),
              let surfaceID = surfaceIdFromPanelId(panelID),
              bonsplitController.selectedTab(inPane: paneID)?.id == surfaceID else { return nil }
        if let terminal = panels[panelID] as? TerminalPanel { return terminal.hostedView }
        if let browser = panels[panelID] as? BrowserPanel { return browser.webView }
        return nil
    }


    /// The cloud resource behind a panel, when the panel projects one.
    func cloudProjectedResource(forPanel panelID: UUID, catalog: SurfaceCatalog? = nil) -> SurfaceResource? {
        let catalog = catalog ?? SurfaceCatalog.shared
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
        guard SurfaceCatalog.shared.hasCloudProjection(panelID: sourcePanelID, workspaceID: id) else { return false }
        // Projection identity survives a missing provider graph during restore
        // or reconnect. A handled Cloud split must not seed a local shell.
        guard let resource = cloudProjectedResource(forPanel: sourcePanelID) else {
            closeUntouchedPane(newPane)
            return true
        }
        let routed = routeCloudPaneTerminalCreate(
            near: resource, sourcePanelID: sourcePanelID,
            destination: .tab(workspaceID: id, paneID: newPane.id.uuidString, index: nil),
            preferredRemoteWorkspaceID: SurfaceCatalog.shared.projection(forPanel: sourcePanelID)?.remoteWorkspaceID,
            focus: true,
            splitDirection: orientation == .horizontal ? .right : .down,
            pendingPane: newPane
        )
        if !routed { closeUntouchedPane(newPane) }
        return true
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
    /// The pane appears at once; the machine reports the terminal into it. A failure
    /// is shown in that pane instead of silently doing nothing, because the user's
    /// gesture otherwise looks dead.
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
        let requestID = cloudPaneCreationFailureStore.beginRequest()
        let request = CloudTerminalCreationRequest(id: requestID)
        let sourceProjection = sourcePanelID.flatMap { catalog.projection(forPanel: $0) }
        if remoteWorkspaceID == nil, sourceProjection?.remoteTabID == nil {
            // No pane exists yet for this request, so the ambiguity is reported on
            // the workspace card rather than inside a pane.
            Task { @MainActor in
                try? await CloudTerminalCreationCoordinator.perform(
                    recorder: AppDelegate.shared?.cloudOperations,
                    onFailure: { error, context in
                        self.presentCloudPaneCreationFailure(machine: machine, error: error, requestID: requestID, context: context, sourcePanelID: sourcePanelID)
                    }
                ) {
                    throw SurfaceCatalogError.ambiguousRemotePlacement(resource.id, workspaceID: "")
                }
            }
            if let pendingPane { closeUntouchedPane(pendingPane) }
            return true
        }
        let reservationDestination: SurfaceDestination = pendingPane.map {
            .tab(workspaceID: id, paneID: $0.id.uuidString, index: nil)
        } ?? destination
        guard let reservation = reserveCloudTerminalPane(machine: machine, at: reservationDestination, focus: focus) else {
            // The pane may have been closed or claimed while Bonsplit was
            // delivering the split callback. Remove only an untouched pane;
            // never leave a handled Cloud request as a blank slot.
            if let pendingPane { closeUntouchedPane(pendingPane) }
            return true
        }

        var scope: [SurfaceMachineID: UUID]?
        let beginProjectionMutation: @MainActor () -> Void = {
            if scope == nil { scope = catalog.beginProjectionMutation(for: [resource.id]) }
        }
        let endProjectionMutation: @MainActor () -> Void = {
            guard let current = scope else { return }
            scope = nil
            catalog.endProjectionMutation(current)
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
                        splitDirection: direction,
                        request: request
                    )
                }
                let workingDirectory = await provider.currentWorkingDirectory(of: resource)
                return try await provider.createTerminal(
                    command: nil,
                    cwd: workingDirectory,
                    name: nil,
                    remoteWorkspaceID: remoteWorkspaceID,
                    request: request
                )
            } catch {
                endProjectionMutation()
                throw error
            }
        }
        runOptimisticCloudTerminalCreation(
            reservation: reservation,
            requestID: requestID,
            destination: destination,
            create: create,
            onStart: beginProjectionMutation,
            onFinish: endProjectionMutation
        )
        return true
    }

    /// Starts a fresh terminal on `machine` (in `remoteWorkspaceID` when given) as a
    /// tab of this workspace's focused pane, optimistically. The Cloud sidebar's
    /// "New Terminal" and an empty remote workspace's open both land here, so they
    /// share the shortcut routes' pane, retry, and failure behavior. Returns false
    /// when the machine has no provider or the pane cannot be reserved.
    @discardableResult
    func openCloudTerminalOptimistically(on machine: SurfaceMachineID, remoteWorkspaceID: String?) -> Bool {
        let catalog = SurfaceCatalog.shared
        guard !machine.isLocal, let provider = catalog.provider(for: machine) else { return false }
        let destination = SurfaceDestination.workspace(id: id, placement: .tab)
        guard let reservation = reserveCloudTerminalPane(machine: machine, at: destination, focus: true) else { return false }
        let requestID = cloudPaneCreationFailureStore.beginRequest()
        let request = CloudTerminalCreationRequest(id: requestID)
        var token: UUID?
        let beginLocalMutation: @MainActor () -> Void = {
            if token == nil { token = catalog.cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: machine) }
        }
        let endLocalMutation: @MainActor () -> Void = {
            guard let current = token else { return }
            token = nil
            catalog.cloudWorkspaceProjectionCoordinator.endLocalMutation(current, on: machine, catalog: catalog)
        }
        let create: CloudTerminalCreationCoordinator.Create = {
            do {
                return try await provider.createTerminal(
                    command: nil, cwd: nil, name: nil,
                    remoteWorkspaceID: remoteWorkspaceID,
                    request: request
                )
            } catch {
                endLocalMutation()
                throw error
            }
        }
        runOptimisticCloudTerminalCreation(
            reservation: reservation,
            requestID: requestID,
            destination: destination,
            create: create,
            onStart: beginLocalMutation,
            onFinish: endLocalMutation
        )
        return true
    }

    /// The shared coordinator run behind every optimistic route: one request id,
    /// one remote create, projection adopting the reserved pane, and pane-local
    /// failure and retry. `onStart`/`onFinish` bracket the projection-suppression
    /// scope the caller chose.
    private func runOptimisticCloudTerminalCreation(
        reservation: CloudTerminalPaneReservation,
        requestID: UUID,
        destination: SurfaceDestination,
        create: @escaping CloudTerminalCreationCoordinator.Create,
        onStart: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        let catalog = SurfaceCatalog.shared
        let store = cloudPaneCreationFailureStore
        let project: CloudTerminalCreationCoordinator.Project = { [weak self, reservation] created in
            guard let self, !self.isRetiredFromOwningTabManager,
                  self.cloudPendingCreations[reservation.panelID] === reservation else {
                onFinish()
                throw CancellationError()
            }
            defer { onFinish() }
            // Focus was granted when the pane appeared; adoption must not steal it
            // back from wherever the user has typed since.
            let result = try await CloudOperationContext.phase(.materialize) {
                try await catalog.project(
                    created.id,
                    into: destination,
                    focus: false,
                    reuseExisting: true,
                    remoteView: created.remoteViews?.count == 1 ? created.remoteViews?.first : nil,
                    adopting: reservation
                )
            }
            self.completeReservedCloudTerminalPane(reservation, adoptedPanelID: result.projection.panelID)
            return result
        }
        reservation.retry = { [weak store] in store?.retry(requestID: requestID) }
        reservation.cancel = { [weak store] in store?.cancel(requestID: requestID) }
        store.run(
            machine: reservation.machine,
            requestID: requestID,
            create: create,
            project: project,
            onStart: { [weak self, reservation] in
                onStart()
                self?.restartReservedCloudTerminalPane(reservation)
            },
            onFinish: onFinish,
            inlineFailure: { [weak self, reservation] error in
                self?.failReservedCloudTerminalPane(reservation, error: error)
            },
            discardProjection: { projection in
                catalog.endProjections(panelID: projection.panelID, reason: .replaced)
            },
            operations: AppDelegate.shared?.cloudOperations
        )
    }

    /// Removes a pane a split created that never received a tab.
    private func closeUntouchedPane(_ pane: PaneID) {
        guard bonsplitController.allPaneIds.contains(pane),
              bonsplitController.tabs(inPane: pane).isEmpty else { return }
        _ = bonsplitController.closePane(pane)
    }

    /// Publishes a non-modal failure card for a cloud terminal request.
    @MainActor
    func presentCloudPaneCreationFailure(machine: SurfaceMachineID, error: Error, requestID: UUID, context: CloudOperationContext? = nil, sourcePanelID: UUID? = nil) {
        #if DEBUG
        cmuxDebugLog("cloud.pane.createFailed machine=\(machine.rawValue) error=\(String(reflecting: error))")
        #endif
        cloudPaneCreationFailureStore.present(machine: machine, error: error, requestID: requestID, context: context, sourcePanelID: sourcePanelID ?? focusedPanelId)
    }
}
