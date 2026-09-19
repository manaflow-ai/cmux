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

    /// Returns false only for a local intent. Every recognized Cloud intent is
    /// accepted here, including one whose provider or anchor is still unavailable.
    func routeCloudPaneTerminalSplit(
        from panelID: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool,
        options: CloudTerminalLaunchOptions = CloudTerminalLaunchOptions()
    ) -> Bool {
        guard let target = cloudTerminalCreationTarget(for: panelID) else { return false }
        guard let pane = paneId(forPanelId: panelID) else { return true }
        let direction: SurfaceSplitDirection = orientation == .horizontal
            ? (insertFirst ? .left : .right) : (insertFirst ? .up : .down)
        return routeCloudTerminalCreate(target: target,
            destination: .split(workspaceID: id, paneID: pane.id.uuidString, direction: direction),
            focus: focus, splitDirection: direction, options: options)
    }

    func routeCloudPaneUISplit(from sourcePanelID: UUID?, into newPane: PaneID, orientation: SplitOrientation) -> Bool {
        guard let target = cloudTerminalCreationTarget(for: sourcePanelID) else { return false }
        return routeCloudTerminalCreate(target: target,
            destination: .tab(workspaceID: id, paneID: newPane.id.uuidString, index: nil),
            focus: true, splitDirection: orientation == .horizontal ? .right : .down, pendingPane: newPane)
    }

    func routeCloudPaneTerminalTab(
        inPane paneID: PaneID, focus: Bool,
        options: CloudTerminalLaunchOptions = CloudTerminalLaunchOptions()
    ) -> Bool {
        let source = bonsplitController.selectedTab(inPane: paneID).flatMap { panelIdFromSurfaceId($0.id) }
        guard let target = cloudTerminalCreationTarget(for: source) else { return false }
        return routeCloudTerminalCreate(target: target,
            destination: .tab(workspaceID: id, paneID: paneID.id.uuidString, index: nil), focus: focus, options: options)
    }

    /// Reservation and execution share the same captured machine. A dependent
    /// shortcut awaits its source pane's projection before choosing the remote tab.
    private func routeCloudTerminalCreate(
        target: CloudTerminalCreationTarget,
        destination: SurfaceDestination,
        focus: Bool,
        splitDirection: SurfaceSplitDirection? = nil,
        pendingPane: PaneID? = nil,
        options: CloudTerminalLaunchOptions = CloudTerminalLaunchOptions()
    ) -> Bool {
        let catalog = SurfaceCatalog.shared
        let requestID = cloudPaneCreationFailureStore.beginRequest()
        let request = CloudTerminalCreationRequest(id: requestID)
        guard let reservation = reserveCloudTerminalPane(machine: target.machine, at: destination, focus: focus) else {
            if let pendingPane { closeUntouchedPane(pendingPane) }
            return true
        }
        if let input = options.input { reservation.inputRelay.send(.bytes(Data(input.utf8))) }
        var scope: UUID?
        let beginMutation: @MainActor () -> Void = {
            if scope == nil { scope = catalog.cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: target.machine) }
        }
        let endMutation: @MainActor () -> Void = {
            guard let token = scope else { return }
            scope = nil
            catalog.cloudWorkspaceProjectionCoordinator.endLocalMutation(token, on: target.machine, catalog: catalog)
        }
        let create: CloudTerminalCreationCoordinator.Create = { [weak self] in
            guard let self, !self.isRetiredFromOwningTabManager,
                  self.cloudPendingCreations[reservation.panelID] === reservation else { throw CancellationError() }
            guard !options.requiresLocalPTY else { throw CloudDiagnosticFailure.unsupported }
            let anchor = try await target.resolve(in: self, catalog: catalog)
            try Task.checkCancellation()
            guard self.cloudPendingCreations[reservation.panelID] === reservation else { throw CancellationError() }
            guard let provider = catalog.provider(for: target.machine) else { throw SurfaceCatalogError.noProvider(target.machine) }
            if !options.needsCustomCommand, let tab = anchor.remoteTabID,
               let layoutProvider = provider as? any SurfaceLayoutTerminalCreating {
                return try await layoutProvider.createTerminal(nearTabID: tab, splitDirection: splitDirection, request: request)
            }
            if anchor.remoteWorkspaceID == nil {
                guard case .machine = target.source else { throw CloudDiagnosticFailure.notFound }
            }
            let cwd: String?
            if let requested = options.workingDirectory { cwd = requested }
            else if let resource = anchor.resource { cwd = await provider.currentWorkingDirectory(of: resource) }
            else { cwd = nil }
            return try await provider.createTerminal(command: options.argv, cwd: cwd, name: nil,
                remoteWorkspaceID: anchor.remoteWorkspaceID, request: request)
        }
        runOptimisticCloudTerminalCreation(reservation: reservation, requestID: requestID,
            destination: destination, create: create, onStart: beginMutation, onFinish: endMutation)
        return true
    }

    /// The sidebar already names a machine; its explicit New Terminal action may
    /// use that machine's current workspace when no workspace was supplied.
    @discardableResult
    func openCloudTerminalOptimistically(on machine: SurfaceMachineID, remoteWorkspaceID: String?) -> Bool {
        guard !machine.isLocal else { return false }
        return routeCloudTerminalCreate(
            target: CloudTerminalCreationTarget(machine: machine, source: .machine(remoteWorkspaceID: remoteWorkspaceID)),
            destination: .workspace(id: id, placement: .tab), focus: true)
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
