import Bonsplit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// The local layout a Cloud tree drop displaced, captured before the drop inserts
/// anything. Every pane one drop reserves shares it, so rolling back any of them
/// restores the selection the user had instead of a neighbor's.
@MainActor
final class CloudSurfaceDropRollback {
    weak var catalog: SurfaceCatalog?
    let previousFocusedPanelID: UUID?
    /// A tab drop changes the target pane's selected tab; a split drop adds a pane.
    let destinationPaneID: PaneID?
    let previousDestinationPanelID: UUID?
    /// Panes this drop reserved, in drop order. A surviving one keeps the drop's
    /// place when a sibling rolls back.
    private(set) var memberPanelIDs: [UUID] = []

    init(
        workspace: Workspace,
        destination: BonsplitController.ExternalTabDropRequest.Destination,
        catalog: SurfaceCatalog
    ) {
        self.catalog = catalog
        previousFocusedPanelID = workspace.focusedPanelId
        if case .insert(let paneID, _) = destination {
            destinationPaneID = paneID
            previousDestinationPanelID = workspace.selectedPanelForPaneDrop(in: paneID)?.panelId
        } else {
            destinationPaneID = nil
            previousDestinationPanelID = nil
        }
    }

    func admit(_ panelID: UUID) { memberPanelIDs.append(panelID) }

    /// Whether `panelID` is the tab the drop's target pane shows. Read before it closes.
    func isDestinationSelection(_ panelID: UUID, in workspace: Workspace) -> Bool {
        guard let paneID = destinationPaneID, let tab = workspace.surfaceIdFromPanelId(panelID) else { return false }
        return workspace.bonsplitController.selectedTab(inPane: paneID)?.id == tab
    }

    /// Reselects what the removed pane displaced: a sibling from the same drop
    /// that is still there, otherwise the pre-drop tab. Focus moves only when the
    /// removed pane held it; otherwise the user's current focus is kept even
    /// though restoring a tab selection moves Bonsplit focus. The workspace focus
    /// transaction always runs, because closing a tab schedules a handoff to its
    /// neighbor that only a newer focus request supersedes.
    func restore(
        in workspace: Workspace,
        removing removedPanelID: UUID,
        wasSelected: Bool,
        wasFocused: Bool,
        focusBeforeRemoval: UUID?
    ) {
        let survivor = memberPanelIDs.first { $0 != removedPanelID && workspace.panels[$0] != nil }
        if wasSelected, let paneID = destinationPaneID {
            let replacement = [survivor, previousDestinationPanelID].compactMap { $0 }
                .first { workspace.paneId(forPanelId: $0) == paneID }
            if let replacement, let tab = workspace.surfaceIdFromPanelId(replacement),
               workspace.bonsplitController.selectedTab(inPane: paneID)?.id != tab {
                workspace.bonsplitController.selectTab(tab)
            }
        }
        let target = wasFocused ? survivor ?? previousFocusedPanelID : focusBeforeRemoval
        guard let target, workspace.panels[target] != nil else { return }
        workspace.focusPanel(target)
    }
}

extension SurfaceCatalog.OptimisticPaneHost {
    /// The host a Cloud tree drop uses: the terminal pane is reserved where the
    /// user dropped it, the provider adopts that same pane once the machine
    /// answers, and any failure removes it and restores `rollback`. A placement
    /// already open in the workspace is focused instead of opened again.
    @MainActor
    static func drop(into workspace: Workspace, catalog: SurfaceCatalog, rollback: CloudSurfaceDropRollback) -> Self {
        var host = Self(
            reserve: { [weak workspace] machine, destination, focus in
                // A provider that cannot adopt would replace the pane it was given.
                guard let workspace, destination.workspaceID == workspace.id,
                      catalog.provider(for: machine) is CmuxTuiSurfaceProvider,
                      let reservation = workspace.reserveCloudTerminalPane(machine: machine, at: destination, focus: focus)
                else { return nil }
                reservation.dropRollback = rollback
                rollback.admit(reservation.panelID)
                return reservation
            },
            attach: { [weak workspace] reservation, resource, remoteTabID in
                workspace?.attachDroppedCloudTerminal(reservation, resource: resource, remoteTabID: remoteTabID, catalog: catalog)
            }
        )
        host.reusesDestinationProjections = true
        return host
    }
}

extension SurfaceCatalog {
    /// The pane already showing this placement in `workspaceID`, pending or attached.
    /// A display counts once per workspace; a terminal matches its exact remote tab.
    /// A resource on this Mac has no second view: dropping it moves its one pane.
    func openProjection(
        of id: SurfaceResourceID,
        remoteView: SurfaceRemoteView?,
        in workspaceID: UUID,
        paneLookup: PaneLookup
    ) -> SurfaceProjection? {
        guard !id.machine.isLocal else { return nil }
        return projections.first { projection in
            guard projection.resource == id, projection.workspaceID == workspaceID,
                  paneLookup(projection.panelID, workspaceID) != nil else { return false }
            guard let remoteView, id.kind == .terminal else { return true }
            return projection.remoteTabID == remoteView.tabID
        }
    }

    /// Reserves one terminal member at `destination` and starts its attachment.
    /// Nil keeps the awaited path: the member is not a known Cloud terminal or
    /// the host cannot reserve a pane there.
    func reserveOptimistically(
        _ member: SurfaceResourcePlacement,
        remoteView: SurfaceRemoteView?,
        into destination: SurfaceDestination,
        focus: Bool,
        host: OptimisticPaneHost
    ) -> SurfaceProjection? {
        guard member.resource.machine.tuiMachineID != nil,
              let resource = resources[member.resource], resource.kind == .terminal,
              !isDeletingCloudResource(resource.id, remoteWorkspaceID: remoteView?.workspace.id),
              let reservation = host.reserve(resource.machine, destination, focus) else { return nil }
        let projection = recordReservedProjection(reservation, placement: member, remoteView: remoteView)
        host.attach(reservation, resource, remoteView?.tabID)
        return projection
    }

    /// Sign-out, a team switch and machine removal all unregister the provider.
    /// A drop still waiting on that machine can never attach, so it rolls back.
    func rollBackCloudSurfaceDrops(on machine: SurfaceMachineID) {
        for projection in projections where projection.resource.machine == machine {
            guard let workspace = Workspace.liveWorkspace(id: projection.workspaceID),
                  let reservation = workspace.cloudPendingCreations[projection.panelID] else { continue }
            workspace.rollBackDroppedCloudTerminalPane(reservation)
        }
    }
}

@MainActor
extension Workspace {
    /// Binds a dropped terminal's reserved pane to its machine terminal in place.
    /// The pane keeps its panel id and the projection recorded at drop time, so
    /// reconciliation never adds a tab. Failure, a stale placement, or a provider
    /// that changed while the attach awaited removes the pane instead.
    func attachDroppedCloudTerminal(
        _ reservation: CloudTerminalPaneReservation,
        resource: SurfaceResource,
        remoteTabID: String?,
        catalog: SurfaceCatalog
    ) {
        let panelID = reservation.panelID
        let remoteView = remoteTabID.flatMap { tab in resource.remoteViews?.first { $0.tabID == tab } }
        let task = Task { @MainActor [weak self] in
            do {
                guard let self, let provider = catalog.provider(for: resource.machine),
                      let paneID = self.paneId(forPanelId: panelID) else { throw CancellationError() }
                let destination = SurfaceDestination.tab(workspaceID: self.id, paneID: paneID.id.uuidString, index: nil)
                let attached = try await provider.materialize(
                    resource, remoteView: remoteView, at: destination, focus: false, adopting: reservation
                )
                // A late answer (the pane closed, sign-out, another team's provider,
                // a delete in flight) or one for another placement never binds the pane.
                guard !Task.isCancelled, self.cloudPendingCreations[panelID] === reservation,
                      catalog.provider(for: resource.machine) === provider,
                      !catalog.isDeletingCloudResource(resource.id, remoteWorkspaceID: remoteView?.workspace.id),
                      attached.panelID == panelID, attached.resource == resource.id, attached.workspaceID == self.id,
                      remoteView == nil || attached.remoteTabID == nil || attached.remoteTabID == remoteView?.tabID else {
                    if attached.panelID == panelID {
                        provider.projectionDidEnd(attached)
                    } else {
                        provider.discardMaterialization(attached)
                    }
                    throw CloudDiagnosticFailure.placement
                }
                // The projection recorded at drop time already names this terminal and
                // tab; only a placement the drop could not know is filled in.
                if let current = catalog.projection(forPanel: panelID), current.remoteTabID == nil,
                   let workspaceID = attached.remoteWorkspaceID, let tabID = attached.remoteTabID {
                    catalog.setRemotePlacement(for: current, placement: SurfaceRemotePlacement(workspaceID: workspaceID, tabID: tabID))
                }
                self.completeReservedCloudTerminalPane(reservation, adoptedPanelID: panelID)
            } catch {
#if DEBUG
                cmuxDebugLog("surfaces.drop.attach.failed panel=\(panelID.uuidString.prefix(5)) error=\(error)")
#endif
                self?.rollBackDroppedCloudTerminalPane(reservation)
            }
        }
        reservation.cancel = { task.cancel() }
    }

    /// Removes a drop's pending pane without touching the machine and restores
    /// the layout and selection the drop displaced. A pane the user already
    /// closed, or one that attached, is no longer pending and is left alone.
    @discardableResult
    func rollBackDroppedCloudTerminalPane(_ reservation: CloudTerminalPaneReservation) -> Bool {
        guard let rollback = reservation.dropRollback,
              cloudPendingCreations[reservation.panelID] === reservation else { return false }
        let panelID = reservation.panelID
        cloudPendingCreations.removeValue(forKey: panelID)
        reservation.inputRelay.discard()
        reservation.creationReceipt.finish(.failure(CloudDiagnosticFailure.placement))
        let cancel = reservation.cancel
        reservation.cancel = nil
        reservation.retry = nil
        cancel?()
        let focusBeforeRemoval = focusedPanelId
        let wasSelected = rollback.isDestinationSelection(panelID, in: self)
        let catalog = rollback.catalog ?? SurfaceCatalog.shared
        catalog.endProjections(panelID: panelID, reason: .replaced)
        catalog.withProjectionEndReason(for: [panelID], reason: .replaced) {
            _ = closePanel(panelID, force: true)
        }
        rollback.restore(
            in: self, removing: panelID, wasSelected: wasSelected,
            wasFocused: focusBeforeRemoval == panelID, focusBeforeRemoval: focusBeforeRemoval
        )
        return true
    }
}
