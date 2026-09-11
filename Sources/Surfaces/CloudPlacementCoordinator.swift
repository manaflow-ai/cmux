import Foundation
import Observation

/// Orders structural edits from every local projection of a machine. Local pane moves
/// remain immediate; confirmed remote coordinates change only after the daemon accepts
/// the edit. A failure is retained and reported rather than silently claiming success.
@MainActor
@Observable
final class CloudPlacementCoordinator {
    private struct Lane {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let binding: @MainActor (UUID) -> WorkspaceCloudVMBinding?
    private let reportFailure: @MainActor (SurfaceProjection, Error) -> Void
    private var lanes: [SurfaceMachineID: Lane] = [:]
    private var failureRefreshes: [SurfaceMachineID: Task<Void, Never>] = [:]
    // These receipts bridge queued move → move → close operations, including a pane
    // already removed locally. They are released as soon as that machine's lane drains.
    private var receipts: [SurfaceResourceID: [UUID: SurfaceRemotePlacement]] = [:]
    private var movedTabs: [SurfaceMachineID: [String: String]] = [:]
    private var closedTabs: [SurfaceMachineID: Set<String>] = [:]
    private var confirmationCursors: [SurfaceMachineID: [String: CloudVMCursor]] = [:]
    private(set) var failures: [SurfaceResourceID: String] = [:]

    init(
        binding: @escaping @MainActor (UUID) -> WorkspaceCloudVMBinding? = { _ in nil },
        reportFailure: @escaping @MainActor (SurfaceProjection, Error) -> Void = { _, _ in }
    ) {
        self.binding = binding
        self.reportFailure = reportFailure
    }

    func boundRemoteWorkspaceID(forLocalWorkspace localWorkspaceID: UUID, on machine: SurfaceMachineID) -> String? {
        guard let vmID = machine.cloudMachineID,
              let binding = binding(localWorkspaceID), binding.vmID == vmID,
              let remote = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remote.isEmpty else { return nil }
        return remote
    }

    /// A bound workspace wins over a stale anchor snapshot after a pane transfer.
    func creationWorkspaceID(in localWorkspaceID: UUID, near resource: SurfaceResource) -> String? {
        boundRemoteWorkspaceID(forLocalWorkspace: localWorkspaceID, on: resource.machine)
            ?? (resource.remoteWorkspaces.first(where: \.focused) ?? resource.remoteWorkspaces.first)?.id
    }

    func confirmPlacement(_ placement: SurfaceRemotePlacement, on machine: SurfaceMachineID) {
        if let cursor = placement.cursor {
            confirmationCursors[machine, default: [:]][placement.tabID] = cursor
        }
    }

    /// Resolve a local VNC pane before binding inference sees its old workspace.
    func projectionInCurrentWorkspace(_ projection: SurfaceProjection) -> SurfaceProjection {
        guard projection.resource.kind == .display, projection.remoteTabID == nil else { return projection }
        var updated = projection
        updated.remoteWorkspaceID = boundRemoteWorkspaceID(
            forLocalWorkspace: projection.workspaceID, on: projection.resource.machine
        )
        return updated
    }

    private func placement(of projection: SurfaceProjection, resource: SurfaceResource, catalog: SurfaceCatalog) -> SurfaceRemotePlacement? {
        let receipt = receipts[resource.id]?[projection.panelID]
        let live = catalog.projection(forPanel: projection.panelID).flatMap { $0.resource == resource.id ? $0 : nil }
        // A local VNC pane must never borrow another viewer's daemon tab on close.
        if resource.kind == .display, receipt == nil, (live ?? projection).remoteTabID == nil { return nil }
        guard let tabID = receipt?.tabID
            ?? catalog.cloudWorkspaceRenameService.remoteTabID(for: live ?? projection, resource: resource) else { return nil }
        guard let workspaceID = movedTabs[resource.machine]?[tabID]
            ?? receipt?.workspaceID
            ?? live?.remoteWorkspaceID
            ?? projection.remoteWorkspaceID
            ?? resource.remoteViews?.first(where: { $0.tabID == tabID })?.workspace.id else { return nil }
        return SurfaceRemotePlacement(workspaceID: workspaceID, tabID: tabID)
    }

    func projectionDidMove(_ projection: SurfaceProjection, catalog: SurfaceCatalog) {
        if projection.resource.kind == .display, projection.remoteTabID == nil {
            // Local VNC membership follows the current binding, including removal
            // when the pane moves into an unbound viewer workspace.
            let current = projectionInCurrentWorkspace(projection)
            catalog.setRemotePlacement(for: projection, workspaceID: current.remoteWorkspaceID, tabID: nil)
            return
        }
        guard let target = boundRemoteWorkspaceID(forLocalWorkspace: projection.workspaceID, on: projection.resource.machine),
              let provider = catalog.provider(for: projection.resource.machine) as? any SurfacePlacementSyncing else { return }
        enqueue(projection, catalog: catalog) {
            guard let resource = catalog.resources[projection.resource] else { return false }
            let current = self.placement(of: projection, resource: resource, catalog: catalog)
            guard current?.workspaceID != target else { return false }
            let result: SurfaceRemotePlacement
            if let current {
                result = try await provider.moveRemoteTab(id: current.tabID, intoRemoteWorkspace: target)
            } else if resource.kind == .terminal, resource.remoteViews?.isEmpty == true,
                      projection.remoteTabID == nil {
                result = try await provider.projectTerminal(resource.id, intoRemoteWorkspace: target)
            } else if resource.kind == .browser && resource.remoteViews?.isEmpty != false {
                // Port previews have no daemon tab; retain their local association.
                catalog.setRemotePlacement(for: projection, workspaceID: target, tabID: nil)
                return true
            } else {
                throw SurfaceCatalogError.unavailable(resource.id, reason: String(
                    localized: "cloudPane.layoutSyncFailed.ambiguous",
                    defaultValue: "The pane does not identify a unique machine tab. Reopen it from the machine workspace."
                ))
            }
            guard catalog.provider(for: resource.machine) === provider else { return false }
            self.receipts[resource.id, default: [:]][projection.panelID] = result
            self.movedTabs[resource.machine, default: [:]][result.tabID] = result.workspaceID
            self.confirmPlacement(result, on: resource.machine)
            catalog.setRemotePlacement(for: projection, placement: result)
            return true
        }
    }

    /// Applies accepted daemon coordinates, including edits from another client. Older
    /// snapshots cannot undo a local move whose mutation receipt is still ahead of them.
    func reconcileRemoteState(_ state: CloudVMState, catalog: SurfaceCatalog) {
        guard lanes[state.machine] == nil else { return }
        var replacements: [SurfaceProjection: SurfaceProjection] = [:]
        for projection in catalog.projections where projection.resource.machine == state.machine {
            guard let tabID = projection.remoteTabID else { continue }
            if let receipt = confirmationCursors[state.machine]?[tabID] {
                guard let cursor = state.cursor else { continue }
                if cursor.generation == receipt.generation && cursor.revision < receipt.revision { continue }
                confirmationCursors[state.machine]?[tabID] = nil
            }
            let trackedTab = state.lookupIndex.tab(id: tabID)
            let contentKind = trackedTab?.contentKind == "screen" ? "display" : trackedTab?.contentKind
            if trackedTab?.contentID != projection.resource.key
                || contentKind != projection.resource.kind.rawValue {
                var updated = projection
                updated.remoteWorkspaceID = nil
                updated.remoteTabID = nil
                replacements[projection] = updated
                continue
            }
            guard let tab = trackedTab,
                  let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID),
                  projection.remoteWorkspaceID != screen.workspaceID else { continue }
            var updated = projection
            updated.remoteWorkspaceID = screen.workspaceID
            replacements[projection] = updated
        }
        catalog.reconcileRemotePlacements(replacements)
        // Receipts for panes closed before confirmation need no retained local state.
        let liveTabIDs = Set(catalog.projections.filter { $0.resource.machine == state.machine }.compactMap(\.remoteTabID))
        confirmationCursors[state.machine] = confirmationCursors[state.machine]?.filter { liveTabIDs.contains($0.key) }
    }

    func projectionDidEnd(_ projection: SurfaceProjection, reason: SurfaceProjectionEndReason, catalog: SurfaceCatalog) {
        guard reason == .paneClosed,
              let bound = boundRemoteWorkspaceID(forLocalWorkspace: projection.workspaceID, on: projection.resource.machine),
              let provider = catalog.provider(for: projection.resource.machine) as? any SurfacePlacementSyncing else { return }
        enqueue(projection, catalog: catalog) {
            guard let resource = catalog.resources[projection.resource],
                  let current = self.placement(of: projection, resource: resource, catalog: catalog),
                  current.workspaceID == bound,
                  self.closedTabs[resource.machine]?.contains(current.tabID) != true else { return false }
            let stillShown = catalog.projections.contains { other in
                other.resource == resource.id
                    && (other.remoteTabID == nil
                        || self.placement(of: other, resource: resource, catalog: catalog)?.tabID == current.tabID)
            }
            guard !stillShown else { return false }
            try await provider.closeRemoteTab(id: current.tabID, inRemoteWorkspace: bound)
            self.closedTabs[resource.machine, default: []].insert(current.tabID)
            return true
        }
    }

    /// Repairs an attachment in the same lane as user edits, so a late reconnect
    /// cannot overwrite a newer move. A viewer may use daemon focus; a mirrored
    /// pane must supply its binding. Conflicting bindings cannot be guessed.
    func repairPlacement(
        for resourceID: SurfaceResourceID,
        catalog: SurfaceCatalog,
        ensure: @escaping @MainActor (String?) async throws -> SurfaceRemotePlacement
    ) async {
        guard let projection = catalog.projections.first(where: { $0.resource == resourceID }),
              let provider = catalog.provider(for: resourceID.machine) else { return }
        let task = enqueue(projection, catalog: catalog, presentFailure: false) {
            let current = catalog.projections.filter { $0.resource == resourceID }
            guard !current.isEmpty else { return false }
            let targets = Set(current.compactMap {
                self.boundRemoteWorkspaceID(forLocalWorkspace: $0.workspaceID, on: resourceID.machine)
            })
            guard targets.count <= 1 else {
                throw SurfaceCatalogError.unavailable(resourceID, reason: String(
                    localized: "cloudPane.layoutSyncFailed.ambiguous",
                    defaultValue: "The pane does not identify a unique machine tab. Reopen it from the machine workspace."
                ))
            }
            let placement = try await ensure(targets.first)
            guard catalog.provider(for: resourceID.machine) === provider else { return false }
            self.confirmPlacement(placement, on: resourceID.machine)
            self.movedTabs[resourceID.machine, default: [:]][placement.tabID] = placement.workspaceID
            // A pane may already be closed locally while its close waits behind
            // this repair. Keep its receipt until the lane drains, too.
            for projection in current {
                self.receipts[resourceID, default: [:]][projection.panelID] = placement
            }
            var replacements: [SurfaceProjection: SurfaceProjection] = [:]
            for projection in catalog.projections where projection.resource == resourceID {
                self.receipts[resourceID, default: [:]][projection.panelID] = placement
                var updated = projection
                updated.remoteWorkspaceID = placement.workspaceID
                updated.remoteTabID = placement.tabID
                replacements[projection] = updated
            }
            catalog.reconcileRemotePlacements(replacements)
            return true
        }
        await task.value
    }

    /// Waits for submitted edits and their failure refreshes without polling snapshots.
    func waitForPendingMutations() async {
        let pending = lanes.values.map(\.task)
        for task in pending { await task.value }
        for refresh in Array(failureRefreshes.values) { await refresh.value }
    }

    private func refreshAfterFailure(machine: SurfaceMachineID, provider: any SurfaceProvider, catalog: SurfaceCatalog) {
        guard failureRefreshes[machine] == nil else { return }
        // Refresh may itself enqueue attachment recovery. Start it outside the
        // mutation lane so it can never await an operation queued behind itself.
        failureRefreshes[machine] = Task { @MainActor in
            defer { self.failureRefreshes[machine] = nil }
            guard catalog.provider(for: machine) === provider else { return }
            await provider.refresh()
        }
    }

    @discardableResult
    private func enqueue(
        _ projection: SurfaceProjection,
        catalog: SurfaceCatalog,
        presentFailure: Bool = true,
        operation: @escaping @MainActor () async throws -> Bool
    ) -> Task<Void, Never> {
        let machine = projection.resource.machine
        let previous = lanes[machine]?.task
        let provider = catalog.provider(for: machine)
        let token = UUID()
        let task = Task { @MainActor in
            await previous?.value
            defer {
                if self.lanes[machine]?.token == token {
                    self.lanes[machine] = nil
                    self.receipts = self.receipts.filter { $0.key.machine != machine }
                    self.movedTabs[machine] = nil
                    self.closedTabs[machine] = nil
                    if let state = catalog.cloudStates[machine] {
                        self.reconcileRemoteState(state, catalog: catalog)
                    }
                }
            }
            // A disconnected/replaced provider must never receive a delayed edit.
            guard let provider, catalog.provider(for: machine) === provider else { return }
            do {
                if try await operation() { self.failures[projection.resource] = nil }
            } catch {
                self.failures[projection.resource] = CloudMachineLink.errorText(error)
                if presentFailure {
                    self.reportFailure(projection, error)
                    self.refreshAfterFailure(machine: machine, provider: provider, catalog: catalog)
                }
            }
        }
        lanes[machine] = Lane(token: token, task: task)
        return task
    }
}
