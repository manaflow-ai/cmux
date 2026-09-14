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
    private let workspaceExists: @MainActor (SurfaceMachineID, String) -> Bool?
    private let reportFailure: @MainActor (SurfaceProjection, Error) -> Void
    private var lanes: [SurfaceMachineID: Lane] = [:]
    private var failureRefreshes: [SurfaceMachineID: Task<Void, Never>] = [:]
    // These receipts bridge queued move → move → close operations, including a pane
    // already removed locally. They are released as soon as that machine's lane drains.
    private var receipts: [SurfaceResourceID: [UUID: SurfaceRemotePlacement]] = [:]
    private var movedTabs: [SurfaceMachineID: [String: String]] = [:]
    private var closedTabs: [SurfaceMachineID: [String: String]] = [:]
    private var confirmationCursors: [SurfaceMachineID: [String: CloudVMCursor]] = [:]
    private(set) var failures: [SurfaceResourceID: String] = [:]

    init(
        binding: @escaping @MainActor (UUID) -> WorkspaceCloudVMBinding? = { _ in nil },
        workspaceExists: @escaping @MainActor (SurfaceMachineID, String) -> Bool? = { _, _ in nil },
        reportFailure: @escaping @MainActor (SurfaceProjection, Error) -> Void = { _, _ in }
    ) {
        self.binding = binding
        self.workspaceExists = workspaceExists
        self.reportFailure = reportFailure
    }

    func boundRemoteWorkspaceID(forLocalWorkspace localWorkspaceID: UUID, on machine: SurfaceMachineID) -> String? {
        guard let vmID = machine.cloudMachineID,
              let binding = binding(localWorkspaceID), binding.vmID == vmID,
              let remote = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remote.isEmpty else { return nil }
        return remote
    }

    /// Selects the remote workspace for a new terminal without reviving a deleted
    /// binding or guessing between several live placements. A binding remains
    /// authoritative when the resource still proves that placement exists; a
    /// selected projection may then provide the exact placement for a mixed layout.
    func creationWorkspaceID(
        in localWorkspaceID: UUID,
        near resource: SurfaceResource,
        preferredRemoteWorkspaceID: String? = nil
    ) -> String? {
        let candidates = Set(resource.remoteWorkspaces.map(\.id))
        if let preferred = preferredRemoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty {
            guard candidates.contains(preferred) || workspaceExists(resource.machine, preferred) == true else { return nil }
            return preferred
        }
        if let bound = boundRemoteWorkspaceID(forLocalWorkspace: localWorkspaceID, on: resource.machine),
           candidates.contains(bound) || workspaceExists(resource.machine, bound) == true {
            return bound
        }
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    func confirmPlacement(_ placement: SurfaceRemotePlacement, on machine: SurfaceMachineID) {
        if let cursor = placement.cursor {
            confirmationCursors[machine, default: [:]][placement.tabID] = cursor
        }
    }

    /// A committed receipt may lead the graph, but cannot outlive a generation
    /// change or an authoritative deletion at or after its revision.
    func hasUnobservedPlacement(tabID: String, on machine: SurfaceMachineID, state: CloudVMState?) -> Bool {
        guard let receipt = confirmationCursors[machine]?[tabID] else { return false }
        guard let cursor = state?.cursor else { return state == nil }
        return cursor.generation == receipt.generation && cursor.revision < receipt.revision
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
        if let state = catalog.cloudStates[resource.machine],
           catalog.cloudStateObservations[resource.machine]?.freshness == .current,
           !hasUnobservedPlacement(tabID: tabID, on: resource.machine, state: state) {
            guard let tab = state.lookupIndex.tab(id: tabID),
                  tab.contentID == resource.id.key,
                  tab.contentKind == resource.kind.rawValue || (resource.kind == .display && tab.contentKind == "screen"),
                  let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else {
                CloudTerminalLifecycleLog().rejected(live ?? projection, stage: "placement-dispatch")
                return nil
            }
            return SurfaceRemotePlacement(workspaceID: screen.workspaceID, tabID: tabID, cursor: state.cursor)
        }
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
        if lanes[projection.resource.machine] == nil, projection.remoteWorkspaceID == target { return }
        enqueue(projection, catalog: catalog) {
            guard let resource = catalog.resources[projection.resource] else { return false }
            let current = self.placement(of: projection, resource: resource, catalog: catalog)
            guard current?.workspaceID != target else { return false }
            let result: SurfaceRemotePlacement
            if let current {
                result = try await provider.moveRemoteTab(id: current.tabID, intoRemoteWorkspace: target)
            } else if resource.kind == .terminal, resource.isDetachedTerminal,
                      projection.remoteTabID == nil || self.isAuthoritativelyDetached(resource, catalog: catalog) {
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

    private func isAuthoritativelyDetached(_ resource: SurfaceResource, catalog: SurfaceCatalog) -> Bool {
        guard let state = catalog.cloudStates[resource.machine],
              catalog.cloudStateObservations[resource.machine]?.freshness == .current,
              state.lookupIndex.terminal(id: resource.id.key)?.lifecycle == "running" else { return false }
        return state.lookupIndex.tabs(contentKind: "terminal", contentID: resource.id.key).isEmpty
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
        closedTabs[state.machine] = closedTabs[state.machine]?.filter { tabID, workspaceID in
            guard let tab = state.lookupIndex.tab(id: tabID), let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else { return false }
            return screen.workspaceID == workspaceID
        }
        // Receipts for panes closed before confirmation need no retained local state.
        let liveTabIDs = Set(catalog.projections.filter { $0.resource.machine == state.machine }.compactMap(\.remoteTabID))
        confirmationCursors[state.machine] = confirmationCursors[state.machine]?.filter { liveTabIDs.contains($0.key) }
    }

    /// A graph preceding a confirmed local move cannot reshape its native view.
    func allowsNativeReconciliation(_ state: CloudVMState) -> Bool {
        guard lanes[state.machine] == nil else { return false }
        return !(confirmationCursors[state.machine] ?? [:]).values.contains { receipt in
            guard let cursor = state.cursor else { return true }
            return cursor.generation == receipt.generation && cursor.revision < receipt.revision
        }
    }

    func isPendingClose(_ placement: SurfaceResourcePlacement, on machine: SurfaceMachineID) -> Bool {
        guard let tabID = placement.remoteTabID, let workspaceID = placement.remoteWorkspaceID else { return false }
        return closedTabs[machine]?[tabID] == workspaceID
    }

    func projectionDidEnd(_ projection: SurfaceProjection, reason: SurfaceProjectionEndReason, catalog: SurfaceCatalog) {
        guard reason == .paneClosed,
              let bound = boundRemoteWorkspaceID(forLocalWorkspace: projection.workspaceID, on: projection.resource.machine),
              let provider = catalog.provider(for: projection.resource.machine) as? any SurfacePlacementSyncing else { return }
        enqueue(projection, catalog: catalog) {
            guard let resource = catalog.resources[projection.resource],
                  let current = self.placement(of: projection, resource: resource, catalog: catalog),
                  current.workspaceID == bound,
                  self.closedTabs[resource.machine]?[current.tabID] != bound else { return false }
            let stillShown = catalog.projections.contains { other in
                other.resource == resource.id
                    && (other.remoteTabID == nil
                        || self.placement(of: other, resource: resource, catalog: catalog)?.tabID == current.tabID)
            }
            guard !stillShown else { return false }
            try await provider.closeRemoteTab(id: current.tabID, inRemoteWorkspace: bound)
            self.closedTabs[resource.machine, default: [:]][current.tabID] = bound
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
            if let state = catalog.cloudStates[resourceID.machine] {
                guard current.contains(where: { catalog.cloudWorkspaceProjectionCoordinator.retainsProjection($0, in: state) }) else { return false }
            }
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
                    if let state = catalog.cloudStates[machine] {
                        self.reconcileRemoteState(state, catalog: catalog)
                        catalog.cloudWorkspaceProjectionCoordinator.request(machine: machine, catalog: catalog)
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
