import CmuxCloud
import CmuxCloudTui
import CmuxSurfaceCatalogModel
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
            var budget = CloudWorkspaceReconcileBudget()
            while self.requested.remove(machine) != nil {
                guard !Task.isCancelled, self.localMutations[machine] == nil else { return }
                await catalog.cloudPlacementCoordinator.waitForPendingMutations()
                guard !Task.isCancelled,
                      self.localMutations[machine] == nil,
                      let state = catalog.cloudStates[machine],
                      catalog.cloudStateObservations[machine]?.freshness == .current,
                      catalog.cloudPlacementCoordinator.allowsNativeReconciliation(state) else { return }
                let progress = CloudWorkspaceReconcileBudget.Mark(
                    state: state,
                    projectionVersion: catalog.projectionVersions[machine, default: 0],
                    bindings: self.environment.bindings().filter { $0.value.vmID == machine.rawValue }
                )
                guard budget.admit(progress) else {
                    self.reportNonConvergence(machine: machine, state: state, budget: budget)
                    return
                }
                await self.reconcile(state: state, catalog: catalog)
            }
        }
        tasks[machine] = CloudWorkspaceProjectionTask(id: id, task: task)
    }

    /// Daemon generation last reported per machine. A persistent re-requester
    /// would otherwise report once for every graph revision.
    private var reportedNonConvergence: [SurfaceMachineID: String] = [:]

    /// Reports non-convergence once per daemon generation, so a trigger outside
    /// this loop that keeps restarting it cannot flood crash reporting.
    private func reportNonConvergence(machine: SurfaceMachineID, state: CloudVMState, budget: CloudWorkspaceReconcileBudget) {
#if DEBUG
        cmuxDebugLog("cloudWorkspace.projection.nonConvergent machine=\(machine.rawValue) passes=\(budget.passes) idle=\(budget.idlePasses)")
#endif
        let generation = state.cursor?.generation ?? ""
        guard reportedNonConvergence[machine] != generation else { return }
        reportedNonConvergence[machine] = generation
        sentryCaptureWarning(
            "Cloud workspace projection did not converge",
            category: "cloud.projection",
            data: [
                "passes": budget.passes, "idlePasses": budget.idlePasses,
                "generation": generation, "revision": state.cursor?.revision ?? 0,
            ]
        )
    }

    /// A bound mirror may not recreate a view that the accepted graph removed.
    /// Unbound viewers retain their existing attachment-repair behavior.
    func retainsProjection(_ projection: SurfaceProjection, in state: CloudVMState) -> Bool {
        guard let binding = environment.bindings()[projection.workspaceID], binding.vmID == state.machine.rawValue,
              let workspaceID = binding.remoteWorkspaceID else { return true }
        let tabs = state.lookupIndex.tabs(contentKind: projection.resource.kind.rawValue, contentID: projection.resource.key)
        if projection.resource.kind == .display && projection.remoteTabID == nil {
            return state.displayMemberships.contains { $0.workspaceID == workspaceID && $0.displayID == projection.resource.key }
        }
        return tabs.contains { tab in
            guard projection.remoteTabID == nil || projection.remoteTabID == tab.id,
                  let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else { return false }
            return screen.workspaceID == workspaceID
        }
    }

    /// Applies the catalog's known display inventory to the graph check. A
    /// frontend row can carry a syntactically valid `display:*` value that is
    /// no longer an exposed display after reconnect; that row must not retain
    /// or recreate a local pane.
    func retainsProjection(
        _ projection: SurfaceProjection,
        in state: CloudVMState,
        catalog: SurfaceCatalog
    ) -> Bool {
        guard retainsProjection(projection, in: state) else { return false }
        guard projection.resource.kind == .display, projection.remoteTabID == nil else { return true }
        return catalog.cloudDisplayMemberships().contains {
            $0.machine == projection.resource.machine
                && $0.displayID == projection.resource.key
                && $0.workspaceID == projection.remoteWorkspaceID
        }
    }

    func cancel(machine: SurfaceMachineID) {
        tasks.removeValue(forKey: machine)?.task.cancel()
        requested.remove(machine)
        localMutations[machine] = nil
        reportedNonConvergence[machine] = nil
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
        let completeness = CloudVMGraphCompleteness(state: state, resources: catalog.snapshot.resources(on: machine))
        for (workspaceID, binding) in environment.bindings() where binding.vmID == machine.rawValue {
            guard let remoteID = binding.remoteWorkspaceID else { continue }
            if catalog.cloudWorkspaceCreationCoordinator.isPending(localWorkspaceID: workspaceID) { continue }
            // A delete owns this workspace's visible lifecycle. Do not let a
            // late projection refresh recreate its panes while the backend
            // request is pending; a committed delete will reconcile them once.
            if catalog.isCloudWorkspaceDeletionPending(machine: machine, workspaceID: remoteID) {
                continue
            }
            guard isCurrent(state, catalog: catalog) else {
                if !Task.isCancelled { requested.insert(machine) }
                return
            }
            // A move is a cross-workspace mutation. Do not let a complete source
            // workspace retire the projection while the destination inventory is
            // still incomplete and cannot reconcile the same tab yet.
            guard completeness.isComplete() else {
                continue
            }
            let group = try? catalog.remoteWorkspaceGroup(machine: machine, workspaceID: remoteID)
            let desired = (group?.placements ?? []).filter {
                !catalog.cloudPlacementCoordinator.isPendingClose($0, on: machine, workspaceID: remoteID)
            }
            let existing = catalog.projections.filter { $0.workspaceID == workspaceID && $0.resource.machine == machine }
            let plan = CloudWorkspaceProjectionPlan(desired: desired, existing: Array(existing))
            do {
                for placement in plan.missing {
                    guard isCurrent(state, catalog: catalog), environment.bindings()[workspaceID] == binding else {
                        if !Task.isCancelled { requested.insert(machine) }
                        return
                    }
                    let view = try catalog.remoteView(
                        for: placement,
                        fallbackWorkspaceID: remoteID
                    )
                    let (projection, _) = try await catalog.project(placement.resource, into: .workspace(id: workspaceID, placement: .tab),
                                                  focus: false, reuseExisting: true, reuseInWorkspace: workspaceID, remoteView: view)
                    adoptOrphanedDisplayMembership(placement, replacedBy: projection, state: state, catalog: catalog)
                }
                guard isCurrent(state, catalog: catalog), environment.bindings()[workspaceID] == binding else {
                    if !Task.isCancelled { requested.insert(machine) }
                    return
                }
                for projection in plan.obsolete {
#if DEBUG
                    cmuxDebugLog("cloudWorkspace.projection.obsolete workspace=\(workspaceID) panel=\(projection.panelID) resource=\(projection.resource.rawValue) remoteWorkspace=\(projection.remoteWorkspaceID ?? "nil") tab=\(projection.remoteTabID ?? "nil") desired=\(desired.count)")
#endif
                    environment.close(projection)
                    catalog.endProjections(panelID: projection.panelID, reason: .replaced)
                }
                let daemonDesired = desired.filter { $0.remoteTabID != nil }
                if let layout = catalog.cloudWorkspaceLayout(machine: machine, workspaceID: remoteID), !daemonDesired.isEmpty,
                   Set(daemonDesired).isSubset(of: Set(layout.placements)) {
                    let live = catalog.projections.filter { $0.workspaceID == workspaceID && $0.resource.machine == machine }
                    environment.applyLayout(workspaceID, layout, Array(live))
                }
                pruneOrphanedDisplayMemberships(remoteWorkspaceID: remoteID, machine: machine, state: state, catalog: catalog)
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

/// Bounds reconciliation of one accepted graph. A pass that changes nothing
/// (same graph, projections and bindings as the pass before) cannot make the
/// next one different, so a few in a row mean a consumer is requesting passes
/// without progress. The hard ceiling also stops a loop that rewrites the same
/// projections every pass, which looks like progress.
struct CloudWorkspaceReconcileBudget {
    struct Mark: Equatable {
        let state: CloudVMState
        let projectionVersion: UInt64
        let bindings: [UUID: WorkspaceCloudVMBinding]
    }

    static let maxIdlePasses = 3
    static let maxPassesPerState = 64

    private var last: Mark?
    private(set) var passes = 0
    private(set) var idlePasses = 0

    /// Records the catalog before a pass; false means stop reconciling this graph.
    mutating func admit(_ mark: Mark) -> Bool {
        if last?.state != mark.state { passes = 0; idlePasses = 0 }
        idlePasses = last == mark ? idlePasses + 1 : 0
        passes += 1
        last = mark
        return idlePasses < Self.maxIdlePasses && passes <= Self.maxPassesPerState
    }
}

@MainActor
extension CloudWorkspaceProjectionCoordinator {
    /// A membership token names the local panel that showed the display. When
    /// that panel is gone (an app restart, or a close whose removal never
    /// landed), the rebuilt pane registers its own token; the old one would
    /// otherwise keep resurrecting the display after every close.
    fileprivate func adoptOrphanedDisplayMembership(
        _ placement: SurfaceResourcePlacement,
        replacedBy projection: SurfaceProjection,
        state: CloudVMState,
        catalog: SurfaceCatalog
    ) {
        guard let viewID = placement.cloudDisplayMembershipViewID,
              viewID != projection.panelID.uuidString.lowercased(),
              let token = state.displayMemberships.first(where: {
                  $0.viewID == viewID && $0.displayID == placement.resource.key
              }),
              // Only this Mac's tokens can be removed; another Mac's view is its own.
              token.clientID == CloudTuiClientPaths().notificationClientID(),
              let provider = catalog.provider(for: placement.resource.machine) as? any CloudDisplayMembershipSyncing
        else { return }
        catalog.cloudPlacementCoordinator.removeOrphanedDisplayMembership(token, provider: provider)
    }

    /// Keeps this Mac's display memberships for an open Cloud workspace equal
    /// to its live display panes. A token whose pane is gone (an old close
    /// whose removal never landed, a crash, a pane rebuilt under a new id)
    /// otherwise shows as a duplicate display row and resurrects the display
    /// after it is closed. Runs only once this machine's restore has settled,
    /// so a pane still being restored keeps its token.
    fileprivate func pruneOrphanedDisplayMemberships(
        remoteWorkspaceID: String,
        machine: SurfaceMachineID,
        state: CloudVMState,
        catalog: SurfaceCatalog
    ) {
        guard !catalog.pendingRestoredProjections.machineIDs.contains(machine),
              let provider = catalog.provider(for: machine) as? any CloudDisplayMembershipSyncing else { return }
        let clientID = CloudTuiClientPaths().notificationClientID()
        let live = Set(catalog.projections
            .filter { $0.resource.machine == machine && $0.resource.kind == .display }
            .map { $0.panelID.uuidString.lowercased() })
        for token in state.displayMemberships
        where token.workspaceID == remoteWorkspaceID && token.clientID == clientID && !live.contains(token.viewID)
            && catalog.cloudPlacementCoordinator.ownedDisplayViewIDs.contains(token.viewID) {
            catalog.cloudPlacementCoordinator.removeOrphanedDisplayMembership(token, provider: provider)
        }
    }
}
