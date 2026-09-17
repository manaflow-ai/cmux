import Foundation

/// Materializes the accepted Cloud graph into bound native workspaces. The graph
/// stays in SurfaceCatalog; this owner holds only cancellable work and local
/// mutation scopes, so snapshot, event and reconnect paths cannot maintain copies.
@MainActor
final class CloudWorkspaceProjectionCoordinator {
    var environment: CloudWorkspaceProjectionEnvironment
    private var tasks: [SurfaceMachineID: CloudWorkspaceProjectionTask] = [:]
    private var requested: Set<SurfaceMachineID> = []
    private var localMutations: [SurfaceMachineID: Set<UUID>] = [:]
    private(set) var failures: [UUID: String] = [:]

    init() {
        self.environment = CloudWorkspaceProjectionEnvironment()
    }

    init(environment: CloudWorkspaceProjectionEnvironment) {
        self.environment = environment
    }

    /// Admission is synchronous, before create/project can yield to a graph event.
    func beginLocalMutation(on machine: SurfaceMachineID) -> UUID {
        let token = UUID()
        localMutations[machine, default: []].insert(token)
        return token
    }

    func endLocalMutation(_ token: UUID, on machine: SurfaceMachineID, catalog: SurfaceCatalog) {
        localMutations[machine]?.remove(token)
        if localMutations[machine]?.isEmpty == true { localMutations[machine] = nil }
        if requested.contains(machine) { request(machine: machine, catalog: catalog) }
    }

    func request(machine: SurfaceMachineID, catalog: SurfaceCatalog) {
        guard !machine.isLocal else { return }
        requested.insert(machine)
        guard tasks[machine] == nil, localMutations[machine] == nil else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self, weak catalog] in
            guard let self else { return }
            defer { if self.tasks[machine]?.id == id { self.tasks[machine] = nil } }
            guard let catalog else { return }
            while self.requested.remove(machine) != nil {
                guard !Task.isCancelled, self.localMutations[machine] == nil else { return }
                await catalog.cloudPlacementCoordinator.waitForPendingMutations()
                guard !Task.isCancelled,
                      self.localMutations[machine] == nil,
                      let state = catalog.cloudStates[machine],
                      catalog.cloudStateObservations[machine]?.freshness == .current,
                      catalog.cloudPlacementCoordinator.allowsNativeReconciliation(state) else { return }
                await self.reconcile(state: state, catalog: catalog)
            }
        }
        tasks[machine] = CloudWorkspaceProjectionTask(id: id, task: task)
    }

    /// A bound mirror may not recreate a view that the accepted graph removed.
    /// Unbound viewers retain their existing attachment-repair behavior.
    func retainsProjection(_ projection: SurfaceProjection, in state: CloudVMState) -> Bool {
        guard let binding = environment.bindings()[projection.workspaceID], binding.vmID == state.machine.rawValue,
              let workspaceID = binding.remoteWorkspaceID else { return true }
        let tabs = state.lookupIndex.tabs(contentKind: projection.resource.kind.rawValue, contentID: projection.resource.key)
        return tabs.contains { tab in
            guard projection.remoteTabID == nil || projection.remoteTabID == tab.id,
                  let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else { return false }
            return screen.workspaceID == workspaceID
        }
    }

    func cancel(machine: SurfaceMachineID) {
        tasks.removeValue(forKey: machine)?.task.cancel()
        requested.remove(machine)
        localMutations[machine] = nil
        let bindings = environment.bindings()
        failures = failures.filter { bindings[$0.key]?.vmID != machine.rawValue }
    }

    func waitForIdle() async {
        for entry in Array(tasks.values) { await entry.task.value }
    }

    private func isCurrent(_ state: CloudVMState, catalog: SurfaceCatalog) -> Bool {
        !Task.isCancelled && localMutations[state.machine] == nil && catalog.cloudStates[state.machine] == state
            && catalog.cloudPlacementCoordinator.allowsNativeReconciliation(state)
    }

    private func reconcile(state: CloudVMState, catalog: SurfaceCatalog) async {
        let machine = state.machine
        for (workspaceID, binding) in environment.bindings() where binding.vmID == machine.rawValue {
            guard let remoteID = binding.remoteWorkspaceID else { continue }
            guard isCurrent(state, catalog: catalog) else {
                if !Task.isCancelled { requested.insert(machine) }
                return
            }
            let group = try? catalog.remoteWorkspaceGroup(machine: machine, workspaceID: remoteID)
            let desired = (group?.placements ?? []).filter {
                !catalog.cloudPlacementCoordinator.isPendingClose($0, on: machine)
            }
            let existing = catalog.projections.filter { $0.workspaceID == workspaceID && $0.resource.machine == machine }
            let plan = CloudWorkspaceProjectionPlan(desired: desired, existing: Array(existing))
            do {
                for placement in plan.missing {
                    guard isCurrent(state, catalog: catalog), environment.bindings()[workspaceID] == binding else {
                        if !Task.isCancelled { requested.insert(machine) }
                        return
                    }
                    let view = try catalog.remoteView(for: placement.resource, tabID: placement.remoteTabID,
                                                      workspaceID: placement.remoteTabID == nil ? nil : remoteID)
                    _ = try await catalog.project(placement.resource, into: .workspace(id: workspaceID, placement: .tab),
                                                  focus: false, reuseExisting: true, reuseInWorkspace: workspaceID, remoteView: view)
                }
                guard isCurrent(state, catalog: catalog), environment.bindings()[workspaceID] == binding else {
                    if !Task.isCancelled { requested.insert(machine) }
                    return
                }
                for projection in plan.obsolete {
                    environment.close(projection)
                    catalog.endProjections(panelID: projection.panelID, reason: .replaced)
                }
                if let layout = catalog.cloudWorkspaceLayout(machine: machine, workspaceID: remoteID), !desired.isEmpty {
                    let live = catalog.projections.filter { $0.workspaceID == workspaceID && $0.resource.machine == machine }
                    environment.applyLayout(workspaceID, layout.includingMissingPlacements(desired), Array(live))
                }
                failures[workspaceID] = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failures[workspaceID] = CloudMachineLink.errorText(error)
            }
        }
        let live = Set(environment.bindings().keys)
        failures = failures.filter { live.contains($0.key) }
    }
}
