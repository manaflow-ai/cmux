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

    private func placement(of projection: SurfaceProjection, resource: SurfaceResource, catalog: SurfaceCatalog) -> SurfaceRemotePlacement? {
        let receipt = receipts[resource.id]?[projection.panelID]
        let live = catalog.projection(forPanel: projection.panelID).flatMap { $0.resource == resource.id ? $0 : nil }
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
            } else if resource.kind == .display || (resource.kind == .browser && resource.remoteViews?.isEmpty != false) {
                // Displays and port previews have no daemon tab; keep their local
                // workspace association without inventing a remote placement.
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
        for projection in catalog.projections where projection.resource.machine == state.machine {
            guard let tabID = projection.remoteTabID else { continue }
            if let receipt = confirmationCursors[state.machine]?[tabID] {
                guard let cursor = state.cursor else { continue }
                if cursor.generation == receipt.generation && cursor.revision < receipt.revision { continue }
                confirmationCursors[state.machine]?[tabID] = nil
            }
            if projection.resource.kind == .terminal,
               state.terminals.contains(where: { $0.id == projection.resource.key }),
               !state.tabs.contains(where: { $0.contentKind == "terminal" && $0.contentID == projection.resource.key }) {
                catalog.setRemotePlacement(for: projection, workspaceID: nil, tabID: nil)
                continue
            }
            guard let tab = state.tabs.first(where: { $0.id == tabID && $0.contentID == projection.resource.key }),
                  let pane = state.panes.first(where: { $0.id == tab.paneID }),
                  let screen = state.screens.first(where: { $0.id == pane.screenID }),
                  projection.remoteWorkspaceID != screen.workspaceID else { continue }
            catalog.setRemotePlacement(for: projection, workspaceID: screen.workspaceID, tabID: tabID)
        }
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
                    && self.placement(of: other, resource: resource, catalog: catalog)?.tabID == current.tabID
            }
            guard !stillShown else { return false }
            try await provider.closeRemoteTab(id: current.tabID, inRemoteWorkspace: bound)
            self.closedTabs[resource.machine, default: []].insert(current.tabID)
            return true
        }
    }

    /// Waits for the edits already submitted by this caller, without polling snapshots.
    func waitForPendingMutations() async {
        let pending = lanes.values.map(\.task)
        for task in pending { await task.value }
    }

    private func enqueue(
        _ projection: SurfaceProjection,
        catalog: SurfaceCatalog,
        operation: @escaping @MainActor () async throws -> Bool
    ) {
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
                self.reportFailure(projection, error)
                await provider.refresh()
            }
        }
        lanes[machine] = Lane(token: token, task: task)
    }
}
