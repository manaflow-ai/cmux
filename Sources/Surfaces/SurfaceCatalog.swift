import Foundation
import Observation

/// The single owner of surface identities and projections on this Mac.
///
/// Rules that hold by construction:
/// - a resource exists in exactly one provider's machine and appears once in `resources`;
/// - a projection is (resource, workspace, panel) and is recorded only by the catalog, when
///   a provider materializes a pane or when an existing pane is adopted at startup/restore;
/// - `project(_:into:)` is the only open path: if the resource is already projected and
///   the caller allows reuse, the existing pane is focused instead of duplicated.
@MainActor
@Observable
final class SurfaceCatalog {
    /// A terminal identity is not enough while a remote terminal has several
    /// placement-local tabs. An explicit tab therefore gets its own single-flight
    /// lane. The nil lane preserves the legacy resource-wide open behavior.
    private struct MaterializationKey: Hashable {
        let resource: SurfaceResourceID
        let remoteTabID: String?

        var machine: SurfaceMachineID { resource.machine }
    }

    static let shared = SurfaceCatalog()

    /// A provider call with no remaining caller must not occupy a resource forever when the
    /// provider ignores task cancellation. The deadline starts only after the last caller
    /// detaches, so a slow but observed materialization is still allowed to finish normally.
    nonisolated static let defaultAbandonedMaterializationTimeout: Duration = .seconds(30)
    nonisolated static let defaultRetiredMaterializationRetention: Duration = .seconds(30)
    nonisolated static let defaultCompletedMaterializationRetention: Duration = .seconds(30)
    /// The coordinator never allows more than this many tasks from one machine to remain tracked
    /// while cancellation is unresolved. This prevents one unhealthy machine from blocking
    /// unrelated machines while also bounding repeated provider replacements.
    nonisolated static let defaultMaximumTrackedMaterializations = 16

    static let didChangeNotification = Notification.Name("cmux.surfaces.didChange")

    private(set) var machines: [SurfaceMachineID: SurfaceMachineInfo] = [:]
    private(set) var resources: [SurfaceResourceID: SurfaceResource] = [:]
    private(set) var projections: Set<SurfaceProjection> = []
    /// Resource IDs grouped by machine so providers can answer presence checks
    /// without sorting the full catalog snapshot on every refresh.
    private var resourceIDsByMachine: [SurfaceMachineID: Set<SurfaceResourceID>] = [:]

    /// The last accepted, revisioned graph for each cloud machine. Resource rows
    /// are derived from this state by the provider; keeping it here makes the
    /// complete state available to socket and agent callers without another cache.
    private(set) var cloudStates: [SurfaceMachineID: CloudVMState] = [:]
    /// Whether each retained graph was observed on a live link. This is separate
    /// from `CloudVMState` because freshness is local observation metadata, not
    /// part of the daemon document or its cursor.
    private(set) var cloudStateObservations: [SurfaceMachineID: CloudVMStateObservation] = [:]
    private var providers: [SurfaceMachineID: any SurfaceProvider] = [:]
    /// The process-wide ordering owner for remote rename intents. A remote identity can
    /// have projections in several local windows, so this cannot live in a TabManager.
    let cloudRenameCoordinator = CloudRenameCoordinator()
    let cloudWorkspaceProjectionCoordinator: CloudWorkspaceProjectionCoordinator
    /// Resolves local workspace owners for cloud rename write-through. The app installs
    /// its live environment at the composition root; tests keep the no-op environment.
    private(set) var cloudWorkspaceRenameService: CloudWorkspaceRenameService
    /// Keeps a mirrored local workspace's panes and its machine workspace's tabs in step.
    private(set) var cloudPlacementCoordinator: CloudPlacementCoordinator
    /// Materializations are asynchronous, so actor reentrancy can otherwise let two callers
    /// pass the reuse check before either provider has returned a projection.
    private var inFlightProjects: [MaterializationKey: SurfaceProjectionMaterialization] = [:]
    /// Tokens for operations that can still report after the catalog moved on. The provider is
    /// held by the provider task itself and passed to the late-result callback, so these sets do
    /// not keep disconnected providers alive. Every token has one bounded eviction task.
    private var retiredMaterializationTokens: Set<UUID> = []
    private var retiredMaterializationEvictionTasks: [UUID: Task<Void, Never>] = [:]
    private var trackedMaterializationTokens: Set<UUID> = []
    private var trackedMaterializationMachines: [UUID: SurfaceMachineID] = [:]
    private var trackedMaterializationCounts: [SurfaceMachineID: Int] = [:]
    private let retiredMaterializationRetention: Duration
    private let completedMaterializationRetention: Duration
    private let abandonedMaterializationTimeout: Duration
    private let maximumTrackedMaterializations: Int
    private let materializationClock: any Clock<Duration>
    /// Panels whose projection was recorded from a restored session before the provider
    /// re-synced; resolved into `projections` once the resource shows up.
    private var projectionEndReasons: [UUID: SurfaceProjectionEndReason] = [:]
    private var pendingRestoredProjections: [SurfaceProjectionRecord: UUID] = [:]

    /// Focus/select behavior the app uses to bring an existing projection forward.
    var focusProjection: ((SurfaceProjection) -> Void)?

    init(
        abandonedMaterializationTimeout: Duration = SurfaceCatalog.defaultAbandonedMaterializationTimeout,
        retiredMaterializationRetention: Duration = SurfaceCatalog.defaultRetiredMaterializationRetention,
        completedMaterializationRetention: Duration = SurfaceCatalog.defaultCompletedMaterializationRetention,
        maximumTrackedMaterializations: Int = SurfaceCatalog.defaultMaximumTrackedMaterializations,
        materializationClock: any Clock<Duration> = ContinuousClock(),
        cloudWorkspaceRenameService: CloudWorkspaceRenameService = CloudWorkspaceRenameService(),
        cloudPlacementCoordinator: CloudPlacementCoordinator? = nil,
        cloudWorkspaceProjectionCoordinator: CloudWorkspaceProjectionCoordinator? = nil
    ) {
        precondition(abandonedMaterializationTimeout > .zero)
        precondition(retiredMaterializationRetention > .zero)
        precondition(completedMaterializationRetention > .zero)
        precondition(maximumTrackedMaterializations > 0)
        self.abandonedMaterializationTimeout = abandonedMaterializationTimeout
        self.retiredMaterializationRetention = retiredMaterializationRetention
        self.completedMaterializationRetention = completedMaterializationRetention
        self.maximumTrackedMaterializations = maximumTrackedMaterializations
        self.materializationClock = materializationClock
        self.cloudWorkspaceRenameService = cloudWorkspaceRenameService
        self.cloudPlacementCoordinator = cloudPlacementCoordinator ?? CloudPlacementCoordinator()
        self.cloudWorkspaceProjectionCoordinator = cloudWorkspaceProjectionCoordinator ?? CloudWorkspaceProjectionCoordinator(
            environment: .init(workspaces: cloudWorkspaceRenameService.environment)
        )
    }

    /// Installs the app-owned cloud rename service once the composition root can provide
    /// workspace and tab-manager lookups. The catalog retains ownership after install.
    func installCloudWorkspaceRenameService(_ service: CloudWorkspaceRenameService) {
        cloudWorkspaceRenameService = service
        cloudWorkspaceProjectionCoordinator.environment = .init(workspaces: service.environment)
        cloudPlacementCoordinator = CloudPlacementCoordinator(
            binding: { service.environment.workspace($0)?.cloudVMBinding },
            workspaceExists: { [weak self] machine, remoteWorkspaceID in
                guard let self, let state = self.cloudStates[machine],
                      (self.cloudStateObservations[machine] ?? .current).freshness == .current,
                      state.cursor != nil, state.document.containsCollection("workspaces") else { return nil }
                return state.workspaceIDs.contains(remoteWorkspaceID)
            },
            reportFailure: { projection, error in
                service.environment.workspace(projection.workspaceID)?.presentCloudPlacementFailure(error)
            }
        )
    }

    /// Reconciles a local workspace binding from its exact cloud projections.
    func reconcileCloudWorkspaceBinding(localWorkspaceID: UUID) {
        cloudWorkspaceRenameService.reconcileBinding(
            localWorkspaceID: localWorkspaceID,
            catalog: self
        )
        requestCloudWorkspaceProjection(localWorkspaceID)
    }

    /// Propagates a local workspace title through the catalog's ordered remote lane.
    func propagateCloudWorkspaceRename(
        workspace: Workspace,
        localTitle: String?,
        previousCustomTitle: String?
    ) {
        cloudWorkspaceRenameService.propagate(
            workspace: workspace,
            localTitle: localTitle,
            previousCustomTitle: previousCustomTitle,
            catalog: self
        )
    }

    /// Propagates a local pane title through the exact remote tab placement.
    func propagateCloudTerminalRename(
        workspace: Workspace,
        panelID: UUID,
        resource: SurfaceResource,
        name: String,
        previousCustomTitle: String?
    ) {
        cloudWorkspaceRenameService.propagateTerminalRename(
            workspace: workspace,
            panelID: panelID,
            resource: resource,
            name: name,
            previousCustomTitle: previousCustomTitle,
            catalog: self
        )
    }

    /// Persists the machine and remote workspace identity behind a local workspace.
    func bindCloudWorkspace(
        localWorkspaceID: UUID,
        machine: SurfaceMachineID,
        remoteWorkspaceID: String?,
        generatedTitle: String? = nil
    ) {
        cloudWorkspaceRenameService.bind(
            localWorkspaceID: localWorkspaceID,
            machine: machine,
            remoteWorkspaceID: remoteWorkspaceID,
            generatedTitle: generatedTitle
        )
        requestCloudWorkspaceProjection(localWorkspaceID)
    }

    // MARK: Providers

    func register(_ provider: any SurfaceProvider) {
        if let previous = providers[provider.machine], previous !== provider {
            cloudWorkspaceProjectionCoordinator.cancel(machine: provider.machine)
            let inFlightKeys = inFlightProjects.keys.filter { $0.machine == provider.machine }
            for key in inFlightKeys {
                cancelInFlightProject(key, error: SurfaceCatalogError.unknownResource(key.resource))
            }
        }
        providers[provider.machine] = provider
        machines[provider.machine] = machineInfoPreservingCanonicalCloudState(provider.info)
        if cloudStates[provider.machine] != nil {
            cloudWorkspaceProjectionCoordinator.request(machine: provider.machine, catalog: self)
        }
        notifyChange()
    }

    func unregister(machine: SurfaceMachineID) {
        let inFlightKeys = inFlightProjects.keys.filter { $0.machine == machine }
        for key in inFlightKeys {
            cancelInFlightProject(key, error: SurfaceCatalogError.unknownResource(key.resource))
        }
        // A machine that is gone (deleted, or access ended) takes its URL-backed
        // panes with it: a display or browser pane holds a tokened gateway URL
        // that decays into the hosting provider's raw error page once the
        // workload is dead. Terminal panes stay — their attach process exits and
        // the scrollback is still the user's to read.
        let urlBacked = projections.filter {
            $0.resource.machine == machine
                && ($0.resource.kind == .display || $0.resource.kind == .browser)
        }
        let provider = providers[machine]
        for projection in urlBacked {
            if let provider {
                provider.discardMaterialization(projection)
            } else {
                // The registry removes its provider before calling us during a
                // fleet prune. There is still a real browser/display pane to
                // close, even though no provider remains to do it for us.
                SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
            }
        }
        providers[machine] = nil
        machines[machine] = nil
        for id in resourceIDsByMachine[machine] ?? [] { resources[id] = nil }
        resourceIDsByMachine[machine] = nil
        let pending = pendingRestoredProjections.keys.filter { $0.resource.machine == machine }
        for record in pending { pendingRestoredProjections[record] = nil }
        cloudWorkspaceProjectionCoordinator.cancel(machine: machine)
        cloudStates[machine] = nil
        cloudStateObservations[machine] = nil
        projections = projections.filter { $0.resource.machine != machine }
        notifyChange()
    }

    func provider(for machine: SurfaceMachineID) -> (any SurfaceProvider)? {
        providers[machine]
    }

    /// Only the registered provider of a cloud machine (or the local provider,
    /// registered at launch) may write about it. A provider the fleet has just
    /// pruned can still finish an in-flight refresh and write its machine back;
    /// accepting that write brings a machine the backend already destroyed back
    /// as a sidebar row nothing can refresh or delete.
    private func accepts(writeFor machine: SurfaceMachineID, from source: (any SurfaceProvider)? = nil) -> Bool {
        if machine.isLocal { return true }
        guard let registered = providers[machine] else {
#if DEBUG
            cmuxDebugLog("catalog.write.ignored machine=\(machine.rawValue) reason=unregistered")
#endif
            return false
        }
        // Cloud providers refresh asynchronously. Once a replacement is
        // registered, a late callback from the retired instance must not write
        // through the replacement's catalog entry. Callers that do not have a
        // provider (legacy socket paths) retain the current-provider behavior.
        if let source,
           (source.machine != machine || ObjectIdentifier(registered) != ObjectIdentifier(source)) {
#if DEBUG
            cmuxDebugLog("catalog.write.ignored machine=\(machine.rawValue) reason=retired-provider")
#endif
            return false
        }
        return true
    }

    /// Refreshes one machine without waiting on unrelated cloud links. A
    /// machine-scoped CLI request must not be held hostage by another VM's
    /// reconnect timeout.
    func refresh(machine: SurfaceMachineID, force: Bool = false) async {
        guard let provider = providers[machine] else { return }
        await provider.refresh(force: force)
    }

    func refreshAll(force: Bool = false) async {
        for provider in providers.values {
            await provider.refresh(force: force)
        }
    }

    // MARK: Coordinated cloud renames

    /// The catalog is the only application-level entrypoint for a remote rename.
    /// Provider methods are transport primitives. Keeping coordination here gives
    /// tree, socket, CLI, and local projection paths one ordering and pending-intent
    /// policy.
    func renameRemoteWorkspace(on machine: SurfaceMachineID, id: String, name: String) async throws {
        try await enqueueRemoteWorkspaceRename(on: machine, id: id, name: name).value
    }

    func renameRemoteTab(on machine: SurfaceMachineID, id: String, name: String) async throws {
        try await enqueueRemoteTabRename(on: machine, id: id, name: name).value
    }

    func renameTerminal(on machine: SurfaceMachineID, id: SurfaceResourceID, name: String) async throws {
        guard let provider = providers[machine] else {
            throw SurfaceCatalogError.noProvider(machine)
        }
        let key = CloudRenameCoordinator.Key.terminal(machine: machine, id: id.key)
        let task = cloudRenameCoordinator.enqueue(key: key, pendingName: name) {
            try await provider.renameTerminal(id, name: name)
        }
        try await task.value
    }

    // MARK: Resources (called by providers)

    /// Replace everything the catalog knows about one machine. Projections whose resource
    /// disappeared are kept only if the pane still exists (the pane shows an exited/unknown
    /// terminal until it is closed); the caller prunes dead panes through `endProjection`.
    /// `from` identifies the provider that produced the snapshot, when one is available.
    @discardableResult
    func replaceResources(_ list: [SurfaceResource], on machine: SurfaceMachineID, info: SurfaceMachineInfo? = nil, from source: (any SurfaceProvider)? = nil) -> Bool {
        guard accepts(writeFor: machine, from: source) else { return false }
        for id in resourceIDsByMachine[machine] ?? [] { resources[id] = nil }
        resourceIDsByMachine[machine] = nil
        for resource in list {
            precondition(resource.machine == machine, "resource \(resource.id) reported by the wrong provider")
            resources[resource.id] = resource
            resourceIDsByMachine[machine, default: []].insert(resource.id)
        }
        if let info { machines[machine] = machineInfoPreservingCanonicalCloudState(info) }
        resolvePendingRestoredProjections(on: machine)
        notifyChange()
        return true
    }

    /// Insert or replace one resource. A cloud provider may identify itself with `from` so a
    /// result from a retired provider cannot overwrite a replacement registration.
    func upsert(_ resource: SurfaceResource, from source: (any SurfaceProvider)? = nil) {
        guard accepts(writeFor: resource.machine, from: source) else { return }
        resources[resource.id] = resource
        resourceIDsByMachine[resource.machine, default: []].insert(resource.id)
        resolvePendingRestoredProjections(on: resource.machine)
        notifyChange()
    }

    /// Remove a resource, optionally validating the provider that requested the mutation.
    func remove(_ id: SurfaceResourceID, from source: (any SurfaceProvider)? = nil) {
        guard accepts(writeFor: id.machine, from: source) else { return }
        resources[id] = nil
        resourceIDsByMachine[id.machine]?.remove(id)
        if resourceIDsByMachine[id.machine]?.isEmpty == true {
            resourceIDsByMachine[id.machine] = nil
        }
        notifyChange()
    }

    /// Update machine metadata, optionally validating the provider registration that supplied it.
    func updateMachine(_ info: SurfaceMachineInfo, from source: (any SurfaceProvider)? = nil) {
        guard accepts(writeFor: info.id, from: source) else { return }
        machines[info.id] = machineInfoPreservingCanonicalCloudState(info)
        notifyChange()
    }

    /// Retains the last accepted graph while recording that the transport no
    /// longer proves it current. This is used when the fleet summary reports a
    /// sleeping machine before the provider's next full refresh.
    func markCloudStateStale(
        on machine: SurfaceMachineID,
        reason: String? = nil,
        info: SurfaceMachineInfo? = nil
    ) {
        guard cloudStates[machine] != nil else {
            if let info { machines[machine] = machineInfoPreservingCanonicalCloudState(info) }
            notifyChange()
            return
        }
        var observation = cloudStateObservations[machine] ?? .stale(reason: reason)
        observation.freshness = .stale
        observation.reason = reason
        cloudStateObservations[machine] = observation
        if let info {
            precondition(info.id == machine, "machine info and stale machine disagree")
            machines[machine] = machineInfoPreservingCanonicalCloudState(info)
        }
        notifyChange()
    }

    /// Updates only transient mutation metadata for an already accepted cloud
    /// graph. The daemon document and derived rows remain unchanged. This lets
    /// an agent see a committed write receipt during the refresh that will
    /// confirm it, without treating the receipt as remote state.
    func updateCloudPendingWrites(
        on machine: SurfaceMachineID,
        writes: [CloudVMPendingMutation],
        from source: (any SurfaceProvider)? = nil
    ) {
        guard accepts(writeFor: machine, from: source), cloudStates[machine] != nil else { return }
        var observation = cloudStateObservations[machine] ?? .current
        let pending = writes.isEmpty ? nil : writes
        guard observation.pendingWrites != pending else { return }
        observation.pendingWrites = pending
        cloudStateObservations[machine] = observation
        notifyChange()
    }

    /// Installs one complete cloud graph and all of its derived resource rows as
    /// one catalog transaction. Equal rows are retained, so observers can never
    /// see a new cursor paired with resource rows from the previous revision and
    /// a title-only snapshot does not rebuild every row.
    func replaceCloudState(
        _ state: CloudVMState,
        resources list: [SurfaceResource],
        info: SurfaceMachineInfo,
        observation: CloudVMStateObservation = .current
    ) {
        guard case .cloud = state.machine else { return }
        precondition(info.id == state.machine, "cloud state and machine info disagree")
        _ = installCloudStateRows(
            state,
            resources: list,
            info: info,
            observation: observation
        )
    }

    /// Installs a contiguous delta without replacing equal rows. The daemon graph is still
    /// committed atomically with its derived rows, but a title-only event updates one resource
    /// instead of rebuilding every sidebar row and projection input.
    @discardableResult
    func applyCloudStateDelta(
        _ state: CloudVMState,
        resources list: [SurfaceResource],
        info: SurfaceMachineInfo,
        observation: CloudVMStateObservation = .current
    ) -> Set<SurfaceResourceID> {
        guard case .cloud = state.machine else { return [] }
        precondition(info.id == state.machine, "cloud state and machine info disagree")
        return installCloudStateRows(
            state,
            resources: list,
            info: info,
            observation: observation
        )
    }

    /// Commits a new cloud graph while replacing only the derived rows identified by
    /// `affectedResourceIDs`. Rows outside that set, including synthetic display and port
    /// capabilities, remain untouched. The graph, cursor, machine info, and affected rows are
    /// still one catalog transaction, so an agent never observes a new cursor with mixed rows.
    @discardableResult
    func applyCloudStateResourcePatch(
        _ state: CloudVMState,
        resources list: [SurfaceResource],
        affectedResourceIDs: Set<SurfaceResourceID>,
        info: SurfaceMachineInfo,
        observation: CloudVMStateObservation = .current
    ) -> Set<SurfaceResourceID> {
        guard case .cloud = state.machine else { return [] }
        precondition(info.id == state.machine, "cloud state and machine info disagree")

        var desired: [SurfaceResourceID: SurfaceResource] = [:]
        desired.reserveCapacity(list.count)
        for resource in list {
            precondition(resource.machine == state.machine, "resource \(resource.id) reported by the wrong cloud state")
            precondition(
                affectedResourceIDs.contains(resource.id),
                "resource \(resource.id) is outside the cloud delta impact set"
            )
            desired[resource.id] = resource
        }

        var changed = Set<SurfaceResourceID>()
        let existingIDs = resources.keys.filter {
            $0.machine == state.machine && affectedResourceIDs.contains($0)
        }
        for id in existingIDs where desired[id] == nil {
            if resources.removeValue(forKey: id) != nil { changed.insert(id) }
        }
        for (id, resource) in desired where resources[id] != resource {
            resources[id] = resource
            changed.insert(id)
        }
        // This patch intentionally touches only an impact set. Rebuild the
        // reverse index from the committed rows so a prior replacement or a
        // partial delta can never leave `hasResources` out of sync with the
        // canonical resource map.
        rebuildResourceIndex(for: state.machine)

        cloudStates[state.machine] = state
        cloudStateObservations[state.machine] = observation
        machines[state.machine] = machineInfoPreservingCanonicalCloudState(info, state: state)
        resolvePendingRestoredProjections(on: state.machine)
        notifyChange()
        return changed
    }

    @discardableResult
    private func installCloudStateRows(
        _ state: CloudVMState,
        resources list: [SurfaceResource],
        info: SurfaceMachineInfo,
        observation: CloudVMStateObservation
    ) -> Set<SurfaceResourceID> {
        guard case .cloud = state.machine else { return [] }
        precondition(info.id == state.machine, "cloud state and machine info disagree")

        var desired: [SurfaceResourceID: SurfaceResource] = [:]
        desired.reserveCapacity(list.count)
        for resource in list {
            precondition(resource.machine == state.machine, "resource \(resource.id) reported by the wrong cloud state")
            desired[resource.id] = resource
        }

        let existingIDs = resources.keys.filter { $0.machine == state.machine }
        var changed = Set<SurfaceResourceID>()
        for id in existingIDs where desired[id] == nil {
            if resources.removeValue(forKey: id) != nil { changed.insert(id) }
        }
        for (id, resource) in desired {
            if resources[id] != resource {
                resources[id] = resource
                changed.insert(id)
            }
        }
        rebuildResourceIndex(for: state.machine)
        cloudStates[state.machine] = state
        cloudStateObservations[state.machine] = observation
        machines[state.machine] = machineInfoPreservingCanonicalCloudState(info, state: state)
        resolvePendingRestoredProjections(on: state.machine)
        notifyChange()
        return changed
    }

    func clearCloudState(on machine: SurfaceMachineID) {
        let removedState = cloudStates.removeValue(forKey: machine) != nil
        let removedObservation = cloudStateObservations.removeValue(forKey: machine) != nil
        guard removedState || removedObservation else { return }
        notifyChange()
    }

    /// Atomically publishes the machine's reachable capability rows while its
    /// daemon graph is unavailable. The last accepted graph is retained and
    /// marked stale. A separate `clearCloudState` followed by `replaceResources`
    /// would destroy useful diagnosis state and expose two transitions, which
    /// lets an agent read a half-updated VM.
    func replaceUnavailableCloudState(
        on machine: SurfaceMachineID,
        resources list: [SurfaceResource],
        info: SurfaceMachineInfo,
        pendingWrites: [CloudVMPendingMutation] = []
    ) {
        precondition(info.id == machine, "machine info and unavailable machine disagree")
        if cloudStates[machine] != nil {
            var observation = cloudStateObservations[machine] ?? .stale(reason: info.linkError ?? info.linkState.rawValue)
            observation.freshness = .stale
            observation.reason = info.linkError ?? info.linkState.rawValue
            observation.pendingWrites = pendingWrites.isEmpty ? nil : pendingWrites
            cloudStateObservations[machine] = observation
        } else {
            cloudStateObservations[machine] = pendingWrites.isEmpty
                ? nil
                : CloudVMStateObservation(freshness: .stale, reason: info.linkError ?? info.linkState.rawValue, pendingWrites: pendingWrites)
        }
        for id in Array(resources.keys.filter { $0.machine == machine }) {
            resources[id] = nil
        }
        for resource in list {
            precondition(resource.machine == machine, "resource \(resource.id) reported by the wrong machine")
            resources[resource.id] = resource
        }
        rebuildResourceIndex(for: machine)
        machines[machine] = machineInfoPreservingCanonicalCloudState(info)
        resolvePendingRestoredProjections(on: machine)
        notifyChange()
    }

    /// Rebuilds the machine reverse index after a cloud transaction. Cloud
    /// deltas can replace only a subset of rows, so deriving this set from the
    /// committed map is the invariant-preserving operation.
    private func rebuildResourceIndex(for machine: SurfaceMachineID) {
        let ids = Set(resources.keys.filter { $0.machine == machine })
        resourceIDsByMachine[machine] = ids.isEmpty ? nil : ids
    }

    /// A provider summary can arrive after a newer daemon graph. Keep the graph's
    /// workspace list authoritative so a stale status response cannot regress a
    /// renamed workspace or resurrect a removed one in the tree. Pending creation
    /// rows remain represented by their resource overlays until the next graph.
    private func machineInfoPreservingCanonicalCloudState(
        _ info: SurfaceMachineInfo,
        state: CloudVMState? = nil
    ) -> SurfaceMachineInfo {
        guard case .cloud = info.id,
              let state = state ?? cloudStates[info.id] else { return info }
        var adjusted = info
        let canonical = state.workspaces.map {
            SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
        }
        var seen = Set(canonical.map(\.id))
        // A create response can expose a new empty workspace before the next
        // journal snapshot. Keep such genuinely new rows, but never retain an
        // incoming row whose id the accepted graph removed.
        let pending = (info.remoteWorkspaces ?? []).filter { seen.insert($0.id).inserted }
        adjusted.remoteWorkspaces = canonical + pending
        return adjusted
    }

    // MARK: Projections

    /// The only open path. Reuses an existing projection when `reuseExisting` is set and one
    /// exists (focusing it), otherwise asks the provider to materialize a pane.
    ///
    /// `reuseInWorkspace` narrows reuse to projections in that local workspace: a pane
    /// showing the resource in ANOTHER workspace neither satisfies the open nor steals
    /// focus — the resource materializes at `destination` instead. A workspace's own
    /// Desktop row uses this so "open this workspace's screen" never teleports to a
    /// different workspace's VNC pane. Nil keeps the global open-or-focus jump.
    @discardableResult
    func project(_ id: SurfaceResourceID, into destination: SurfaceDestination, focus: Bool = true, reuseExisting: Bool = true, reuseInWorkspace: UUID? = nil, remoteView: SurfaceRemoteView? = nil) async throws -> (projection: SurfaceProjection, reused: Bool) {
        let scope = beginProjectionMutation(for: [id])
        defer { endProjectionMutation(scope) }
        guard let resource = resources[id] else { throw SurfaceCatalogError.unknownResource(id) }
        // Resolve the opaque tab id against the current graph before any async
        // provider work. A stale view must fail, never silently attach to a
        // different placement after a concurrent daemon update.
        let resolvedRemoteView = try validatedRemoteView(remoteView, for: id)
        let materializationKey = MaterializationKey(resource: id, remoteTabID: resolvedRemoteView?.tabID)
        if reuseExisting, let existing = projections.first(where: {
            guard $0.resource == id, reuseInWorkspace == nil || $0.workspaceID == reuseInWorkspace else { return false }
            // An explicit remote view is a placement identity. Reusing a pane
            // attached to a different tab would make a later rename hit the
            // wrong daemon object.
            // An explicit placement must match an explicit projection. A legacy
            // projection with no tab id is not safe to reuse because it may be
            // showing another tab of the same terminal.
            return resolvedRemoteView == nil || $0.remoteTabID == resolvedRemoteView?.tabID
        }) {
            try claimCompletedMaterializationIfNeeded(materializationKey, projection: existing)
            let resolved = attachRemoteView(resolvedRemoteView, to: existing)
            if resource.kind != .terminal,
               let provider = providers[id.machine] as? CmuxTuiSurfaceProvider,
               let browser = SurfacePaneFactory.browserPanel(panelID: resolved.panelID, in: resolved.workspaceID),
               (browser.cloudAccess.model == nil || browser.cloudAccess.model?.phase == .closed),
               let raw = resource.url, let url = URL(string: raw) {
                provider.configureBrowser(browser, url: url)
            }
            if focus { focusProjection?(resolved) }
            return (resolved, true)
        }
        guard let provider = providers[id.machine] else { throw SurfaceCatalogError.noProvider(id.machine) }

        // Workspace-scoped reuse missed: an in-flight materialization bound elsewhere
        // must not be adopted either (it would land — and focus — in that other
        // workspace), so scoped calls go straight to a fresh materialization.
        if reuseExisting, reuseInWorkspace == nil {
            let waiterID = UUID()
            let result = try await withTaskCancellationHandler {
                try await awaitMaterialization(
                    key: materializationKey,
                    id: id,
                    resource: resource,
                    remoteView: resolvedRemoteView,
                    provider: provider,
                    destination: destination,
                    focus: focus,
                    waiterID: waiterID
                )
            } onCancel: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.cancelInFlightProjectWaiter(materializationKey, waiterID: waiterID)
                }
            }
            return try finalizeMaterializationWaiter(
                key: materializationKey,
                id: id,
                waiterID: waiterID,
                result: result,
                focus: focus
            )
        }

        let projection = try await provider.materialize(resource, remoteView: resolvedRemoteView, at: destination, focus: focus)
        guard !Task.isCancelled, providers[id.machine] === provider else {
            provider.discardMaterialization(projection)
            throw CancellationError()
        }
        do { try validateMaterializedProjection(projection, requestedView: resolvedRemoteView) }
        catch { provider.discardMaterialization(projection); throw error }
        record(projection)
        cloudPlacementCoordinator.projectionDidMove(projection, catalog: self)
        return (projection, false)
    }

    private func awaitMaterialization(
        key: MaterializationKey,
        id: SurfaceResourceID,
        resource: SurfaceResource,
        remoteView: SurfaceRemoteView?,
        provider: any SurfaceProvider,
        destination: SurfaceDestination,
        focus: Bool,
        waiterID: UUID
    ) async throws -> SurfaceProjectionMaterialization.Result {
        try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }

            if let inFlight = inFlightProjects[key], let completedProjection = inFlight.completedProjection {
                var completed = inFlight
                completed.pendingAcknowledgements.insert(waiterID)
                inFlightProjects[key] = completed
                continuation.resume(returning: (projection: completedProjection, reused: true))
                return
            }
            if let inFlight = inFlightProjects[key], inFlight.provider !== provider {
                cancelInFlightProject(key, error: SurfaceCatalogError.unknownResource(id))
            }
            if var inFlight = inFlightProjects[key] {
                inFlight.abandoned = false
                inFlight.abandonmentDeadlineTask?.cancel()
                inFlight.abandonmentDeadlineTask = nil
                inFlight.waiters[waiterID] = (reused: true, continuation: continuation)
                inFlightProjects[key] = inFlight
                return
            }

            guard trackedMaterializationCounts[provider.machine, default: 0] < maximumTrackedMaterializations else {
                continuation.resume(throwing: SurfaceCatalogError.unavailable(id, reason: "materialization capacity exhausted"))
                return
            }

            let token = UUID()
            trackMaterialization(token, for: provider)
            let task = Task { @MainActor [weak self] in
                do {
                    let projection = try await provider.materialize(resource, remoteView: remoteView, at: destination, focus: focus)
                    self?.finishInFlightProject(key, token: token, provider: provider, result: .success(projection))
                } catch {
                    self?.finishInFlightProject(key, token: token, provider: provider, result: .failure(error))
                }
            }
            inFlightProjects[key] = SurfaceProjectionMaterialization(
                token: token,
                provider: provider,
                task: task,
                abandonmentDeadlineTask: nil,
                waiters: [waiterID: (reused: false, continuation: continuation)],
                completedProjection: nil,
                completionOwnsProjection: false,
                pendingAcknowledgements: [],
                completionCleanupTask: nil
            )
        }
    }

    private func finishInFlightProject(
        _ key: MaterializationKey,
        token: UUID,
        provider: any SurfaceProvider,
        result: Result<SurfaceProjection, any Error>
    ) {
        let id = key.resource
        guard var inFlight = inFlightProjects[key], inFlight.token == token else {
            releaseTrackedMaterialization(token)
            if retiredMaterializationTokens.remove(token) != nil {
                retiredMaterializationEvictionTasks.removeValue(forKey: token)?.cancel()
            }
            if case .success(let projection) = result {
                cleanupMaterialization(projection, from: provider)
            }
            return
        }
        inFlight.abandonmentDeadlineTask?.cancel()
        releaseTrackedMaterialization(token)

        switch result {
        case .success(let projection):
            guard !inFlight.abandoned else {
                inFlightProjects[key] = nil
                cleanupMaterialization(projection, from: inFlight.provider)
                return
            }
            guard resources[id] != nil else {
                inFlightProjects[key] = nil
                cleanupMaterialization(projection, from: inFlight.provider)
                resume(inFlight.waiters, throwing: SurfaceCatalogError.unknownResource(id))
                return
            }
            do { try validateMaterializedProjection(projection, requestedTabID: key.remoteTabID) }
            catch {
                inFlightProjects[key] = nil
                cleanupMaterialization(projection, from: inFlight.provider)
                resume(inFlight.waiters, throwing: error)
                return
            }
            let returnedProjection: SurfaceProjection
            let ownsProjection: Bool
            if let existing = projections.first(where: {
                $0.resource == id
                    && (key.remoteTabID == nil || $0.remoteTabID == key.remoteTabID)
            }) {
                if existing.panelID != projection.panelID {
                    cleanupMaterialization(projection, from: inFlight.provider)
                }
                returnedProjection = existing
                ownsProjection = false
            } else {
                record(projection)
                returnedProjection = projection
                ownsProjection = true
            }
            let waiters = inFlight.waiters
            inFlight.waiters.removeAll()
            inFlight.completedProjection = returnedProjection
            inFlight.completionOwnsProjection = ownsProjection
            inFlight.pendingAcknowledgements = Set(waiters.keys)
            inFlight.completionCleanupTask = completedMaterializationCleanupTask(key: key, token: token)
            inFlightProjects[key] = inFlight
            for waiter in waiters.values {
                waiter.continuation.resume(
                    returning: (projection: returnedProjection, reused: ownsProjection ? waiter.reused : true)
                )
            }
            if waiters.isEmpty {
                discardUnclaimedMaterializationIfEmpty(key)
            }
        case .failure(let error):
            inFlightProjects[key] = nil
            resume(inFlight.waiters, throwing: error)
        }
    }

    /// Finish the caller side of a successful materialization as one actor-isolated operation.
    /// The cancellation check and acknowledgement share the same turn, so cancellation cannot
    /// leave a newly recorded pane ownerless between those two actions.
    private func finalizeMaterializationWaiter(
        key: MaterializationKey,
        id: SurfaceResourceID,
        waiterID: UUID,
        result: SurfaceProjectionMaterialization.Result,
        focus: Bool
    ) throws -> SurfaceProjectionMaterialization.Result {
        guard !Task.isCancelled else {
            cancelCompletedMaterialization(key, waiterID: waiterID)
            throw CancellationError()
        }
        guard resources[id] != nil else {
            cancelCompletedMaterialization(key, waiterID: waiterID)
            throw SurfaceCatalogError.unknownResource(id)
        }
        guard let projection = self.projection(forPanel: result.projection.panelID),
              projection.resource == id, projection.workspaceID == result.projection.workspaceID else {
            cancelCompletedMaterialization(key, waiterID: waiterID)
            throw SurfaceCatalogError.unavailable(id, reason: "projection closed while opening")
        }
        acknowledgeMaterialization(key, waiterID: waiterID)
        if !result.reused { cloudPlacementCoordinator.projectionDidMove(projection, catalog: self) }
        if result.reused, focus { focusProjection?(projection) }
        return (projection, result.reused)
    }

    private func acknowledgeMaterialization(_ key: MaterializationKey, waiterID: UUID) {
        guard let inFlight = inFlightProjects[key], inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.contains(waiterID) else { return }
        // One accepted result gives the pane an owner. The other resumed callers no longer need
        // bookkeeping because their later cancellation must not close a pane this caller owns.
        inFlight.completionCleanupTask?.cancel()
        inFlightProjects[key] = nil
    }

    private func claimCompletedMaterializationIfNeeded(
        _ key: MaterializationKey,
        projection: SurfaceProjection
    ) throws {
        guard let inFlight = inFlightProjects[key],
              let completedProjection = inFlight.completedProjection,
              completedProjection.resource == projection.resource,
              completedProjection.panelID == projection.panelID else { return }
        guard !Task.isCancelled else { throw CancellationError() }
        inFlight.completionCleanupTask?.cancel()
        inFlightProjects[key] = nil
    }

    private func cancelCompletedMaterialization(_ key: MaterializationKey, waiterID: UUID) {
        guard var inFlight = inFlightProjects[key],
              inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.remove(waiterID) != nil else { return }
        if inFlight.pendingAcknowledgements.isEmpty {
            inFlightProjects[key] = nil
            inFlight.completionCleanupTask?.cancel()
            if inFlight.completionOwnsProjection {
                cleanupRecordedMaterialization(inFlight)
            }
        } else {
            inFlightProjects[key] = inFlight
        }
    }

    /// Handles the defensive empty-set case without retaining a completed operation. Normal
    /// provider completions always have at least one waiter unless every caller cancelled first.
    private func discardUnclaimedMaterializationIfEmpty(_ key: MaterializationKey) {
        guard let inFlight = inFlightProjects[key],
              inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.isEmpty else { return }
        inFlightProjects[key] = nil
        inFlight.completionCleanupTask?.cancel()
        if inFlight.completionOwnsProjection {
            cleanupRecordedMaterialization(inFlight)
        }
    }

    private func completedMaterializationCleanupTask(key: MaterializationKey, token: UUID) -> Task<Void, Never> {
        let timeout = completedMaterializationRetention
        let clock = materializationClock
        return Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireCompletedMaterialization(key, token: token)
        }
    }

    /// A caller can be dropped without cancellation, so completion bookkeeping needs a bounded
    /// recovery path. An acknowledged result is removed before this deadline; otherwise the
    /// operation is treated as unclaimed and any pane owned by it is discarded.
    private func expireCompletedMaterialization(_ key: MaterializationKey, token: UUID) {
        guard let inFlight = inFlightProjects[key],
              inFlight.token == token,
              inFlight.completedProjection != nil,
              !inFlight.pendingAcknowledgements.isEmpty else { return }
        inFlightProjects[key] = nil
        inFlight.completionCleanupTask?.cancel()
        if inFlight.completionOwnsProjection {
            cleanupRecordedMaterialization(inFlight)
        }
    }

    private func cleanupRecordedMaterialization(_ materialization: SurfaceProjectionMaterialization) {
        guard let projection = materialization.completedProjection else { return }
        let provider = materialization.provider
        let current = projections.first {
            $0.resource == projection.resource && $0.panelID == projection.panelID
        }
        let preserved = provider.discardMaterialization(current ?? projection)
        // A completed operation owns only the projection it recorded. If that projection was
        // removed before cleanup, a preserving provider must not resurrect the closed pane.
        guard let current, !preserved else { return }
        projections.remove(current)
        notifyChange()
    }

    /// Cleans up a provider result that arrived after its catalog operation was retired. A
    /// preserving provider moved an existing pane, so its late result must remain represented.
    private func cleanupMaterialization(_ projection: SurfaceProjection, from provider: any SurfaceProvider) {
        let preserved = provider.discardMaterialization(projection)
        guard preserved,
              providers[projection.resource.machine] === provider,
              resources[projection.resource] != nil,
              !projections.contains(where: {
                  $0.resource == projection.resource && $0.panelID == projection.panelID
              }) else { return }
        record(projection)
    }

    private func trackMaterialization(_ token: UUID, for provider: any SurfaceProvider) {
        trackedMaterializationTokens.insert(token)
        trackedMaterializationMachines[token] = provider.machine
        trackedMaterializationCounts[provider.machine, default: 0] += 1
    }

    private func releaseTrackedMaterialization(_ token: UUID) {
        guard trackedMaterializationTokens.remove(token) != nil,
              let machine = trackedMaterializationMachines.removeValue(forKey: token) else { return }
        let remaining = (trackedMaterializationCounts[machine] ?? 1) - 1
        if remaining > 0 {
            trackedMaterializationCounts[machine] = remaining
        } else {
            trackedMaterializationCounts[machine] = nil
        }
    }

    private func cancelInFlightProjectWaiter(_ key: MaterializationKey, waiterID: UUID) {
        guard let current = inFlightProjects[key] else { return }
        if current.completedProjection != nil {
            cancelCompletedMaterialization(key, waiterID: waiterID)
            return
        }
        var inFlight = current
        guard let waiter = inFlight.waiters.removeValue(forKey: waiterID) else { return }
        if inFlight.waiters.isEmpty {
            // Cancellation detaches this caller, but the provider operation stays single-flight
            // until it settles. Provider cancellation is cooperative, so starting another call
            // here would allow an unbounded number of remote panes to race the first one. The
            // abandonment deadline below is the recovery boundary for a provider that never
            // observes cancellation.
            inFlight.abandoned = true
            let token = inFlight.token
            let timeout = abandonedMaterializationTimeout
            let clock = materializationClock
            inFlight.abandonmentDeadlineTask = Task { @MainActor [weak self, clock] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.expireAbandonedMaterialization(key, token: token)
            }
        }
        inFlightProjects[key] = inFlight
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Retire a detached provider operation after its bounded recovery window. New callers can
    /// start a fresh operation immediately while the old task drains cooperatively.
    private func expireAbandonedMaterialization(_ key: MaterializationKey, token: UUID) {
        guard let inFlight = inFlightProjects[key],
              inFlight.token == token,
              inFlight.completedProjection == nil,
              inFlight.abandoned,
              inFlight.waiters.isEmpty else { return }
        inFlightProjects[key] = nil
        inFlight.abandonmentDeadlineTask?.cancel()
        retireMaterialization(token)
        inFlight.task.cancel()
    }

    /// Keep only a short-lived token for a retired operation. A late success is always stale,
    /// so `finishInFlightProject` can discard it directly with the provider captured by its task
    /// even after this token has been evicted.
    private func retireMaterialization(_ token: UUID) {
        precondition(trackedMaterializationTokens.contains(token))
        retiredMaterializationTokens.insert(token)
        let timeout = retiredMaterializationRetention
        let clock = materializationClock
        let evictionTask = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.evictRetiredMaterialization(token)
        }
        guard retiredMaterializationTokens.contains(token) else {
            evictionTask.cancel()
            return
        }
        retiredMaterializationEvictionTasks[token] = evictionTask
    }

    private func evictRetiredMaterialization(_ token: UUID) {
        guard retiredMaterializationTokens.remove(token) != nil else { return }
        retiredMaterializationEvictionTasks.removeValue(forKey: token)?.cancel()
        // The provider may ignore cancellation and never report a result. Once the bounded
        // retirement window ends, stop counting that operation against its machine. A later
        // completion releases the token idempotently and still receives stale-result cleanup.
        releaseTrackedMaterialization(token)
    }

    private func cancelInFlightProject(_ key: MaterializationKey, error: any Error) {
        guard let current = inFlightProjects[key], current.completedProjection == nil,
              let inFlight = inFlightProjects.removeValue(forKey: key) else { return }
        inFlight.abandonmentDeadlineTask?.cancel()
        retireMaterialization(inFlight.token)
        inFlight.task.cancel()
        let waiters = inFlight.waiters
        resume(waiters, throwing: error)
    }

    private func resume(
        _ waiters: [UUID: (reused: Bool, continuation: CheckedContinuation<SurfaceProjectionMaterialization.Result, Error>)],
        throwing error: any Error
    ) {
        for waiter in waiters.values {
            waiter.continuation.resume(throwing: error)
        }
    }

    /// Records a materialized pane and reconciles it with the installed graph.
    func record(_ projection: SurfaceProjection) {
        insertSupersedingLocalPlaceholder(cloudPlacementCoordinator.projectionInCurrentWorkspace(projection))
        reconcileCloudWorkspaceBinding(localWorkspaceID: projection.workspaceID)
        reconcileCloudProjection(projection)
        notifyChange()
    }

    /// A restored placeholder yields to its native pane without authoring a layout edit.
    /// Keep the exact saved view, or the receipt of a backing tab just created for it.
    func replaceProjection(
        _ previous: SurfaceProjection,
        withPanel panelID: UUID,
        in workspaceID: UUID,
        remotePlacement: SurfaceRemotePlacement?
    ) {
        let views = resources[previous.resource]?.remoteViews
        let exactView = views?.first { $0.tabID == previous.remoteTabID }
        // A dead saved ID cannot describe the rematerialized terminal. A unique
        // live view is unambiguous; several live views must remain unresolved.
        let view = exactView ?? (views?.count == 1 ? views?.first : nil)
        let savedWorkspace = views == nil ? previous.remoteWorkspaceID : nil
        let savedTab = views == nil ? previous.remoteTabID : nil
        if let remotePlacement {
            cloudPlacementCoordinator.confirmPlacement(remotePlacement, on: previous.resource.machine)
        }
        endProjections(panelID: previous.panelID, reason: .replaced)
        record(SurfaceProjection(
            resource: previous.resource,
            workspaceID: workspaceID,
            panelID: panelID,
            remoteWorkspaceID: remotePlacement?.workspaceID ?? view?.workspace.id ?? savedWorkspace,
            remoteTabID: remotePlacement?.tabID ?? view?.tabID ?? savedTab
        ))
    }

    /// Fills a legacy projection's missing remote coordinates, or replaces a
    /// stale coordinate only when the caller explicitly supplied the same tab.
    /// The set remains the single owner of projection identity.
    @discardableResult
    private func attachRemoteView(_ view: SurfaceRemoteView?, to projection: SurfaceProjection) -> SurfaceProjection {
        guard let view,
              projection.remoteTabID == nil || projection.remoteTabID == view.tabID else { return projection }
        projections.remove(projection)
        var updated = projection
        updated.remoteWorkspaceID = view.workspace.id
        updated.remoteTabID = view.tabID
        projections.insert(updated)
        reconcileCloudWorkspaceBinding(localWorkspaceID: updated.workspaceID)
        notifyChange()
        return updated
    }

    /// A pane can show one resource. When a remote resource is projected into a pane the
    /// local provider already registered as a plain local terminal (the pane is created
    /// first, then attached), the local placeholder yields: its projection ends and the
    /// local resource disappears, so the pane counts once, as the remote terminal.
    private func insertSupersedingLocalPlaceholder(_ projection: SurfaceProjection) {
        if !projection.resource.machine.isLocal {
            for existing in projections where existing.panelID == projection.panelID && existing.resource.machine.isLocal {
                projections.remove(existing)
                resources[existing.resource] = nil
                resourceIDsByMachine[existing.resource.machine]?.remove(existing.resource)
                if resourceIDsByMachine[existing.resource.machine]?.isEmpty == true {
                    resourceIDsByMachine[existing.resource.machine] = nil
                }
            }
        }
        projections.insert(projection)
    }

    /// Carries a transition owner's intent through the synchronous panel-map observer.
    /// Nested scopes restore the previous reason, and rejected closes leave no marker.
    func withProjectionEndReason<Result>(
        for panelIDs: [UUID],
        reason: SurfaceProjectionEndReason,
        perform operation: () throws -> Result
    ) rethrows -> Result {
        let previous = panelIDs.map { ($0, projectionEndReasons[$0]) }
        for panelID in panelIDs { projectionEndReasons[panelID] = reason }
        defer {
            for (panelID, reason) in previous { projectionEndReasons[panelID] = reason }
        }
        return try operation()
    }

    /// A pane went away. Remote resources live on; a pane closed on purpose inside a
    /// mirrored workspace also closes its machine tab (`CloudPlacementCoordinator`).
    func endProjections(panelID: UUID, reason: SurfaceProjectionEndReason = .paneClosed) {
        let ended = projections.filter { $0.panelID == panelID }
        guard !ended.isEmpty else { return }
        projections.subtract(ended)
        for projection in ended {
            cloudPlacementCoordinator.projectionDidEnd(projection, reason: projectionEndReasons[panelID] ?? reason, catalog: self)
            providers[projection.resource.machine]?.projectionDidEnd(projection)
        }
        notifyChange()
    }

    func moveProjections(panelID: UUID, to workspaceID: UUID) {
        let moved = projections.filter { $0.panelID == panelID && $0.workspaceID != workspaceID }
        guard !moved.isEmpty else { return }
        projections.subtract(moved)
        for var projection in moved {
            projection.workspaceID = workspaceID
            projection = cloudPlacementCoordinator.projectionInCurrentWorkspace(projection)
            projections.insert(projection)
        }
        reconcileCloudWorkspaceBinding(localWorkspaceID: workspaceID)
        for projection in projections where projection.panelID == panelID {
            cloudPlacementCoordinator.projectionDidMove(projection, catalog: self)
        }
        notifyChange()
    }

    /// Applies one accepted graph's coordinate changes in O(changed projections).
    func reconcileRemotePlacements(_ replacements: [SurfaceProjection: SurfaceProjection]) {
        guard !replacements.isEmpty else { return }
        for (previous, updated) in replacements where projections.contains(previous) {
            projections.remove(previous)
            projections.insert(updated)
        }
        notifyChange()
    }

    /// Updates every view of an exact tab together; a late result cannot replace a
    /// different resource that has since taken over the same local panel.
    func setRemotePlacement(for source: SurfaceProjection, placement: SurfaceRemotePlacement) {
        setRemotePlacement(for: source, workspaceID: placement.workspaceID, tabID: placement.tabID)
    }

    func setRemotePlacement(for source: SurfaceProjection, workspaceID: String?, tabID: String?) {
        let matching = projections.filter {
            $0.resource == source.resource && ($0.panelID == source.panelID
                || (tabID != nil && $0.remoteTabID == tabID))
        }
        for var projection in matching {
            projections.remove(projection)
            projection.remoteWorkspaceID = workspaceID
            projection.remoteTabID = tabID
            projections.insert(projection)
        }
        notifyChange()
    }

    func projections(of id: SurfaceResourceID) -> [SurfaceProjection] {
        projections.filter { $0.resource == id }.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    /// Resolves an agent-provided remote placement against the latest accepted
    /// graph. A workspace id alone is valid only when it identifies one view;
    /// callers that need a particular tab must provide `tabID`.
    func remoteView(
        for id: SurfaceResourceID,
        tabID: String? = nil,
        workspaceID: String? = nil
    ) throws -> SurfaceRemoteView? {
        guard let resource = resources[id] else { throw SurfaceCatalogError.unknownResource(id) }
        guard let views = resource.remoteViews else {
            if tabID != nil || workspaceID != nil {
                throw SurfaceCatalogError.unavailable(id, reason: "remote placement data is unavailable")
            }
            return nil
        }
        if let tabID {
            let matches = views.filter { $0.tabID == tabID }
            guard matches.count == 1, let view = matches.first else {
                if matches.count > 1 {
                    throw SurfaceCatalogError.unavailable(id, reason: "remote tab \(tabID) has ambiguous placement")
                }
                throw SurfaceCatalogError.unavailable(id, reason: "remote tab \(tabID) is no longer present")
            }
            if let workspaceID, view.workspace.id != workspaceID {
                throw SurfaceCatalogError.unavailable(id, reason: "remote tab \(tabID) is not in workspace \(workspaceID)")
            }
            return view
        }
        guard let workspaceID else { return nil }
        let matches = views.filter { $0.workspace.id == workspaceID }
        guard matches.count <= 1 else {
            throw SurfaceCatalogError.ambiguousRemotePlacement(id, workspaceID: workspaceID)
        }
        guard let view = matches.first else {
            throw SurfaceCatalogError.unavailable(id, reason: "remote workspace \(workspaceID) has no view of this resource")
        }
        return view
    }

    func projection(forPanel panelID: UUID) -> SurfaceProjection? {
        projections.first { $0.panelID == panelID }
    }

    func resource(forPanel panelID: UUID) -> SurfaceResource? {
        projection(forPanel: panelID).flatMap { resources[$0.resource] }
    }

    /// Persisted identity remains available for presentation before discovery.
    func projectionIdentity(forPanel panelID: UUID, in workspaceID: UUID) -> SurfaceProjectionRecord? {
        if let pending = pendingRestoredProjections.first(where: { $0.key.panelID == panelID && $0.value == workspaceID }) { return pending.key }
        if let live = projection(forPanel: panelID), live.workspaceID == workspaceID {
            return SurfaceProjectionRecord(panelID: panelID, resource: live.resource,
                remoteWorkspaceID: live.remoteWorkspaceID, remoteTabID: live.remoteTabID)
        }
        return nil
    }

    func machineInfo(for machine: SurfaceMachineID) -> SurfaceMachineInfo? {
        machines[machine]
    }

    // MARK: Restore
    /// Records persisted projections for panes the session restore recreated. The projection
    /// becomes live as soon as the provider reports the resource again (a cloud terminal
    /// after the link reconnects); local resources are re-registered by the local provider
    /// with the same panel-derived key, so they resolve immediately.
    func restore(_ records: [SurfaceProjectionRecord], workspaceID: UUID) {
        for record in records {
            if resources[record.resource] != nil {
                insertSupersedingLocalPlaceholder(SurfaceProjection(
                    resource: record.resource,
                    workspaceID: workspaceID,
                    panelID: record.panelID,
                    remoteWorkspaceID: record.remoteWorkspaceID,
                    remoteTabID: record.remoteTabID
                ))
            } else {
                pendingRestoredProjections[record] = workspaceID
            }
        }
        reconcileCloudWorkspaceBinding(localWorkspaceID: workspaceID)
        notifyChange()
    }

    func projectionRecords(forWorkspace workspaceID: UUID) -> [SurfaceProjectionRecord] {
        projections
            .filter { $0.workspaceID == workspaceID }
            .map {
                SurfaceProjectionRecord(
                    panelID: $0.panelID,
                    resource: $0.resource,
                    remoteWorkspaceID: $0.remoteWorkspaceID,
                    remoteTabID: $0.remoteTabID
                )
            }
            .sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    /// Cloud machine IDs referenced by restored panes that are waiting for a
    /// provider to report their resources. The registry uses these IDs during
    /// stale-machine reconciliation so a deleted ID cannot attach old panes
    /// when a different machine later receives the same ID.
    var pendingRestoredMachineIDs: Set<String> {
        Set(pendingRestoredProjections.keys.compactMap { $0.resource.machine.cloudMachineID })
    }

    /// Returns whether at least one resource is currently published for a machine.
    /// This is intentionally unsorted and does not materialize a snapshot.
    func hasResources(on machine: SurfaceMachineID) -> Bool {
        !(resourceIDsByMachine[machine]?.isEmpty ?? true)
    }

    /// Returns the current resources projected in a workspace in one pass. Rename
    /// fallback logic only needs membership, not the stable panel ordering exposed by
    /// `projectionRecords(forWorkspace:)`.
    func resourcesProjected(inWorkspace workspaceID: UUID) -> [SurfaceResource] {
        projections.compactMap { projection in
            guard projection.workspaceID == workspaceID else { return nil }
            return resources[projection.resource]
        }
    }

    private func resolvePendingRestoredProjections(on machine: SurfaceMachineID) {
        var resolvedWorkspaceIDs = Set<UUID>()
        for (record, workspaceID) in pendingRestoredProjections where record.resource.machine == machine {
            guard resources[record.resource] != nil else { continue }
            insertSupersedingLocalPlaceholder(SurfaceProjection(
                resource: record.resource,
                workspaceID: workspaceID,
                panelID: record.panelID,
                remoteWorkspaceID: record.remoteWorkspaceID,
                remoteTabID: record.remoteTabID
            ))
            pendingRestoredProjections[record] = nil
            resolvedWorkspaceIDs.insert(workspaceID)
        }
        for workspaceID in resolvedWorkspaceIDs {
            reconcileCloudWorkspaceBinding(localWorkspaceID: workspaceID)
        }
    }

    // MARK: Snapshot
    var snapshot: SurfaceCatalogSnapshot {
        let orderedMachines = machines.values.sorted { lhs, rhs in
            if lhs.id.isLocal != rhs.id.isLocal { return lhs.id.isLocal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let orderedResources = resources.values.sorted { lhs, rhs in
            if lhs.machine != rhs.machine { return lhs.machine.rawValue < rhs.machine.rawValue }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            let li = lhs.remoteWorkspace?.index ?? -1, ri = rhs.remoteWorkspace?.index ?? -1
            if li != ri { return li < ri }
            return lhs.id.key < rhs.id.key
        }
        return SurfaceCatalogSnapshot(
            machines: orderedMachines,
            resources: orderedResources,
            projections: projections.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
        )
    }

    /// Complete export for the local control socket. This is separate from
    /// `snapshot` because sidebar redraws do not need to copy or hash the full
    /// remote daemon documents.
    var export: SurfaceCatalogExport {
        let retainedObservations = cloudStateObservations.filter { cloudStates[$0.key] != nil }
        return SurfaceCatalogExport(
            catalog: snapshot,
            cloudStates: cloudStates.values.sorted { $0.machine.rawValue < $1.machine.rawValue },
            cloudStateObservations: retainedObservations
        )
    }

    /// Observers get at most one notification per main-runloop turn: a burst of upserts
    /// (a busy shell retitling, a snapshot replacing dozens of resources) collapses into
    /// one hop, so the sidebar rebuilds once instead of once per mutation.
    private var changeNotificationPending = false

    private func notifyChange() {
        guard !changeNotificationPending else { return }
        changeNotificationPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.changeNotificationPending = false
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
