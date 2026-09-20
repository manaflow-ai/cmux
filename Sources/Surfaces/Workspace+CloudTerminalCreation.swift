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

    /// Captures ownership and exact placement in one MainActor turn, including
    /// panes whose create has not returned its catalog projection yet.
    func cloudTerminalSourcePlacement(forPanel panelID: UUID) -> CloudTerminalSourcePlacement? {
        guard panels[panelID] != nil else { return nil }
        let catalog = SurfaceCatalog.shared
        if let projection = catalog.projection(forPanel: panelID) {
            guard projection.workspaceID == id, !projection.resource.machine.isLocal else { return nil }
            let resource = catalog.resources[projection.resource]
            let remoteWorkspaceID = projection.remoteWorkspaceID ?? resource.flatMap {
                catalog.cloudPlacementCoordinator.creationWorkspaceID(in: id, near: $0)
            }
            return CloudTerminalSourcePlacement(
                machine: projection.resource.machine, resource: resource,
                remoteWorkspaceID: remoteWorkspaceID, remoteTabID: projection.remoteTabID
            )
        }
        if let record = catalog.projectionRecord(forPanel: panelID), !record.resource.machine.isLocal {
            let resource = catalog.resources[record.resource]
            let remoteWorkspaceID = record.remoteWorkspaceID ?? resource.flatMap {
                catalog.cloudPlacementCoordinator.creationWorkspaceID(in: id, near: $0)
            }
            return CloudTerminalSourcePlacement(
                machine: record.resource.machine, resource: resource,
                remoteWorkspaceID: remoteWorkspaceID, remoteTabID: record.remoteTabID
            )
        }
        if let reservation = cloudPendingCreations[panelID] {
            return CloudTerminalSourcePlacement(
                machine: reservation.machine, remoteWorkspaceID: reservation.remoteWorkspaceID,
                pendingCreation: reservation.creationReceipt
            )
        }
        // A disconnected provider may remove its graph while the native remote
        // transport remains. Absence of graph metadata is not local ownership.
        if let machineID = (panels[panelID] as? TerminalPanel)?.cloudAttachment?.machineID {
            return CloudTerminalSourcePlacement(machine: .cloud(machineID))
        }
        return nil
    }

    func rejectCloudTerminalCreation(source: CloudTerminalSourcePlacement, panelID: UUID) -> TerminalPanelCreationOutcome {
        presentCloudPaneCreationFailure(
            machine: source.machine, error: CloudDiagnosticFailure.unsupported,
            requestID: cloudPaneCreationFailureStore.beginRequest(), sourcePanelID: panelID
        )
        return .failed
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
        guard let source = cloudTerminalSourcePlacement(forPanel: panelID),
              let paneID = paneId(forPanelId: panelID) else { return false }
        let direction: SurfaceSplitDirection = orientation == .horizontal
            ? (insertFirst ? .left : .right)
            : (insertFirst ? .up : .down)
        return routeCloudPaneTerminalCreate(
            source: source, sourcePanelID: panelID,
            destination: .split(workspaceID: id, paneID: paneID.id.uuidString, direction: direction),
            focus: focus
        )
    }

    /// Routes a bonsplit UI split (the pane-divider split button) whose source pane
    /// projects a cloud resource: the already-created empty pane receives the machine's
    /// new terminal as its first tab. Returns false when the source is not cloud-anchored.
    func routeCloudPaneUISplit(from sourcePanelID: UUID, into newPane: PaneID, orientation: SplitOrientation) -> Bool {
        guard let source = cloudTerminalSourcePlacement(forPanel: sourcePanelID) else { return false }
        let routed = routeCloudPaneTerminalCreate(
            source: source, sourcePanelID: sourcePanelID,
            destination: .tab(workspaceID: id, paneID: newPane.id.uuidString, index: nil),
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
        guard let selectedTab = bonsplitController.selectedTab(inPane: paneID),
              let selectedPanelID = panelIdFromSurfaceId(selectedTab.id),
              let source = cloudTerminalSourcePlacement(forPanel: selectedPanelID) else { return false }
        return routeCloudPaneTerminalCreate(
            source: source, sourcePanelID: selectedPanelID,
            destination: .tab(workspaceID: id, paneID: paneID.id.uuidString, index: nil),
            focus: focus
        )
    }

    /// Creates a terminal using the captured source placement and projects it at `destination`.
    /// The pane appears at once; the machine reports the terminal into it. A failure
    /// is shown in that pane instead of silently doing nothing, because the user's
    /// gesture otherwise looks dead.
    private func routeCloudPaneTerminalCreate(
        source: CloudTerminalSourcePlacement,
        sourcePanelID: UUID?,
        destination: SurfaceDestination,
        focus: Bool,
        splitDirection: SurfaceSplitDirection? = nil,
        pendingPane: PaneID? = nil
    ) -> Bool {
        let catalog = SurfaceCatalog.shared
        let machine = source.machine
        let requestID = cloudPaneCreationFailureStore.beginRequest()
        guard let provider = catalog.provider(for: machine) else {
            presentCloudPaneCreationFailure(machine: machine, error: SurfaceCatalogError.noProvider(machine),
                                            requestID: requestID, sourcePanelID: sourcePanelID)
            return false
        }
        guard source.remoteWorkspaceID != nil || source.pendingCreation != nil else {
            presentCloudPaneCreationFailure(machine: machine, error: CloudDiagnosticFailure.placement,
                                            requestID: requestID, sourcePanelID: sourcePanelID)
            return false
        }
        if let remoteWorkspaceID = source.remoteWorkspaceID,
           catalog.isCloudWorkspaceDeletionHidden(machine: machine, workspaceID: remoteWorkspaceID) {
            presentCloudPaneCreationFailure(machine: machine, error: CloudDiagnosticFailure.placement,
                                            requestID: requestID, sourcePanelID: sourcePanelID)
            if let pendingPane { closeUntouchedPane(pendingPane) }
            return true
        }
        let request = CloudTerminalCreationRequest(id: requestID, remoteWorkspaceID: source.remoteWorkspaceID)
        let reservationDestination: SurfaceDestination = pendingPane.map {
            .tab(workspaceID: id, paneID: $0.id.uuidString, index: nil)
        } ?? destination
        guard let reservation = reserveCloudTerminalPane(
            machine: machine,
            at: reservationDestination,
            focus: focus,
            sourcePlacement: source
        ) else {
            // The pane may have been closed or claimed while Bonsplit was
            // delivering the split callback. Remove only an untouched pane;
            // never leave a handled Cloud request as a blank slot.
            if let pendingPane { closeUntouchedPane(pendingPane) }
            return true
        }

        var token: UUID?
        let beginProjectionMutation: @MainActor () -> Void = {
            if token == nil { token = catalog.cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: machine) }
        }
        let endProjectionMutation: @MainActor () -> Void = {
            guard let current = token else { return }
            token = nil
            catalog.cloudWorkspaceProjectionCoordinator.endLocalMutation(current, on: machine, catalog: catalog)
        }
        let create: CloudTerminalCreationCoordinator.Create = {
            do {
                let resolvedSource = try await source.resolved()
                guard let resolvedWorkspaceID = resolvedSource.remoteWorkspaceID,
                      !resolvedWorkspaceID.isEmpty else { throw CloudDiagnosticFailure.placement }
                request.bind(remoteWorkspaceID: resolvedWorkspaceID)
                guard catalog.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
                try catalog.checkCloudWorkspaceNavigation(machine: machine, workspaceID: resolvedWorkspaceID)
                let created: SurfaceResource
                if let sourceTabID = resolvedSource.remoteTabID,
                   let layoutProvider = provider as? any SurfaceLayoutTerminalCreating {
                    let direction: SurfaceSplitDirection?
                    if case .split(_, _, let requested) = destination { direction = requested }
                    else { direction = splitDirection }
                    created = try await layoutProvider.createTerminal(
                        nearTabID: sourceTabID, splitDirection: direction, request: request
                    )
                } else {
                    let workingDirectory: String?
                    if let resource = resolvedSource.resource { workingDirectory = await provider.currentWorkingDirectory(of: resource) }
                    else { workingDirectory = nil }
                    guard catalog.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
                    try catalog.checkCloudWorkspaceNavigation(machine: machine, workspaceID: resolvedWorkspaceID)
                    created = try await provider.createTerminal(
                        command: nil, cwd: workingDirectory, name: nil,
                        remoteWorkspaceID: resolvedWorkspaceID, request: request
                    )
                }
                guard catalog.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
                try resolvedSource.validate(created: created)
                return created
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
        if let remoteWorkspaceID,
           catalog.isCloudWorkspaceDeletionHidden(machine: machine, workspaceID: remoteWorkspaceID) {
            // This was a handled Cloud action, but its target disappeared while
            // the row was still visible. Do not fall through to the awaited
            // fallback, which could create a terminal for the deleted workspace.
            return true
        }
        let destination = SurfaceDestination.workspace(id: id, placement: .tab)
        guard let reservation = reserveCloudTerminalPane(
            machine: machine, at: destination, focus: true,
            sourcePlacement: CloudTerminalSourcePlacement(machine: machine, remoteWorkspaceID: remoteWorkspaceID)
        ) else { return false }
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
                if let remoteWorkspaceID {
                    if catalog.isCloudWorkspaceDeletionHidden(machine: machine, workspaceID: remoteWorkspaceID) {
                        self.discardReservedCloudTerminalPane(reservation)
                        throw CancellationError()
                    }
                    try catalog.checkCloudWorkspaceNavigation(machine: machine, workspaceID: remoteWorkspaceID)
                }
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
            let remoteView = try reservation.sourcePlacement.remoteView(of: created)
            // Focus was granted when the pane appeared; adoption must not steal it
            // back from wherever the user has typed since.
            let result = try await CloudOperationContext.phase(.materialize) {
                try await catalog.project(
                    created.id,
                    into: destination,
                    focus: false,
                    reuseExisting: false,
                    remoteView: remoteView,
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
            create: {
                do {
                    let created = try await create()
                    try Task.checkCancellation()
                    try reservation.sourcePlacement.validate(created: created)
                    reservation.creationReceipt.finish(.success(created))
                    return created
                } catch {
                    let failure: Error = CloudDiagnosticFailure.classify(error) == .cancelled ? CloudDiagnosticFailure.placement : error
                    reservation.creationReceipt.finish(.failure(failure))
                    throw error
                }
            },
            project: project,
            onStart: { [weak self, reservation] in
                reservation.creationReceipt.beginAttempt()
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
