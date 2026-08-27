import Foundation
import Observation

/// A provider owns the resources of one machine and knows how to put one on screen.
/// Providers push resource changes into the catalog (`catalog.replaceResources`) and the
/// catalog asks them to materialize a projection. They never track projections themselves.
@MainActor
protocol SurfaceProvider: AnyObject {
    var machine: SurfaceMachineID { get }
    var info: SurfaceMachineInfo { get }
    /// Re-sync from the source of truth (machine list, link snapshot, local panels).
    func refresh() async
    /// Create the pane that shows `resource` at `destination` and return the panel it created
    /// (or reused). The catalog records the projection.
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection
    /// Create a new terminal on this machine (remote providers create it in the cmux-tui
    /// session; the local provider spawns a shell) and return its resource.
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource
    /// Called when a pane projecting one of this provider's resources goes away. Remote
    /// providers do nothing (the resource lives on); the local provider drops the resource.
    func projectionDidEnd(_ projection: SurfaceProjection)
    /// End a terminal on this machine (the process and its remote tab). Providers that
    /// cannot (the local machine) throw `SurfaceCatalogError.unsupported`.
    func closeTerminal(_ id: SurfaceResourceID) async throws
    /// Create a new workspace on this machine with its first terminal, the way ⌘N does
    /// locally. Returns the workspace and that terminal's resource.
    func createRemoteWorkspace(name: String?) async throws -> (workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource)
    /// Close a workspace on this machine and every terminal in it.
    func closeRemoteWorkspace(id: String) async throws
    /// Close a pane that was created for a materialization but lost a race with an existing
    /// projection. The default implementation handles providers that use the shared pane
    /// factory; providers may also clear provider-specific bookkeeping. Return true when the
    /// provider preserved the projection, as the local provider does for a moved pane.
    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool
}

extension SurfaceProvider {
    func closeTerminal(_ id: SurfaceResourceID) async throws {
        throw SurfaceCatalogError.unsupported("closing terminals on \(machine)")
    }
    func createRemoteWorkspace(name: String?) async throws -> (workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource) {
        throw SurfaceCatalogError.unsupported("creating workspaces on \(machine)")
    }
    func closeRemoteWorkspace(id: String) async throws {
        throw SurfaceCatalogError.unsupported("closing workspaces on \(machine)")
    }
    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }
}

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
    static let shared = SurfaceCatalog()

    /// A provider call with no remaining caller must not occupy a resource forever when the
    /// provider ignores task cancellation. The deadline starts only after the last caller
    /// detaches, so a slow but observed materialization is still allowed to finish normally.
    static let defaultAbandonedMaterializationTimeout: Duration = .seconds(30)
    static let defaultRetiredMaterializationRetention: Duration = .seconds(30)
    static let defaultCompletedMaterializationRetention: Duration = .seconds(30)
    /// The coordinator never allows more than this many tasks from one machine to remain tracked
    /// while cancellation is unresolved. This prevents one unhealthy machine from blocking
    /// unrelated machines while also bounding repeated provider replacements.
    static let defaultMaximumTrackedMaterializations = 16

    static let didChangeNotification = Notification.Name("cmux.surfaces.didChange")

    private(set) var machines: [SurfaceMachineID: SurfaceMachineInfo] = [:]
    private(set) var resources: [SurfaceResourceID: SurfaceResource] = [:]
    private(set) var projections: Set<SurfaceProjection> = []
    private var providers: [SurfaceMachineID: any SurfaceProvider] = [:]
    /// Materializations are asynchronous, so actor reentrancy can otherwise let two callers
    /// pass the reuse check before either provider has returned a projection.
    private var inFlightProjects: [SurfaceResourceID: SurfaceProjectionMaterialization] = [:]
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
    private var pendingRestoredProjections: [SurfaceProjectionRecord: UUID] = [:]

    /// Focus/select behavior the app uses to bring an existing projection forward.
    var focusProjection: ((SurfaceProjection) -> Void)?

    init(
        abandonedMaterializationTimeout: Duration = SurfaceCatalog.defaultAbandonedMaterializationTimeout,
        retiredMaterializationRetention: Duration = SurfaceCatalog.defaultRetiredMaterializationRetention,
        completedMaterializationRetention: Duration = SurfaceCatalog.defaultCompletedMaterializationRetention,
        maximumTrackedMaterializations: Int = SurfaceCatalog.defaultMaximumTrackedMaterializations,
        materializationClock: any Clock<Duration> = ContinuousClock()
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
    }

    // MARK: Providers

    func register(_ provider: any SurfaceProvider) {
        if let previous = providers[provider.machine], previous !== provider {
            let inFlightIDs = inFlightProjects.keys.filter { $0.machine == provider.machine }
            for id in inFlightIDs {
                cancelInFlightProject(id, error: SurfaceCatalogError.unknownResource(id))
            }
        }
        providers[provider.machine] = provider
        machines[provider.machine] = provider.info
        notifyChange()
    }

    func unregister(machine: SurfaceMachineID) {
        let inFlightIDs = inFlightProjects.keys.filter { $0.machine == machine }
        for id in inFlightIDs {
            cancelInFlightProject(id, error: SurfaceCatalogError.unknownResource(id))
        }
        providers[machine] = nil
        machines[machine] = nil
        let gone = resources.keys.filter { $0.machine == machine }
        for id in gone { resources[id] = nil }
        projections = projections.filter { $0.resource.machine != machine }
        notifyChange()
    }

    func provider(for machine: SurfaceMachineID) -> (any SurfaceProvider)? {
        providers[machine]
    }

    func refreshAll() async {
        for provider in providers.values {
            await provider.refresh()
        }
    }

    // MARK: Resources (called by providers)

    /// Replace everything the catalog knows about one machine. Projections whose resource
    /// disappeared are kept only if the pane still exists (the pane shows an exited/unknown
    /// terminal until it is closed); the caller prunes dead panes through `endProjection`.
    func replaceResources(_ list: [SurfaceResource], on machine: SurfaceMachineID, info: SurfaceMachineInfo? = nil) {
        for id in resources.keys where id.machine == machine {
            resources[id] = nil
        }
        for resource in list {
            precondition(resource.machine == machine, "resource \(resource.id) reported by the wrong provider")
            resources[resource.id] = resource
        }
        if let info { machines[machine] = info }
        resolvePendingRestoredProjections(on: machine)
        notifyChange()
    }

    func upsert(_ resource: SurfaceResource) {
        resources[resource.id] = resource
        resolvePendingRestoredProjections(on: resource.machine)
        notifyChange()
    }

    func remove(_ id: SurfaceResourceID) {
        resources[id] = nil
        notifyChange()
    }

    func updateMachine(_ info: SurfaceMachineInfo) {
        machines[info.id] = info
        notifyChange()
    }

    // MARK: Projections

    /// The only open path. Reuses an existing projection when `reuseExisting` is set and one
    /// exists (focusing it), otherwise asks the provider to materialize a pane.
    @discardableResult
    func project(_ id: SurfaceResourceID, into destination: SurfaceDestination, focus: Bool = true, reuseExisting: Bool = true) async throws -> (projection: SurfaceProjection, reused: Bool) {
        guard let resource = resources[id] else { throw SurfaceCatalogError.unknownResource(id) }
        if reuseExisting, let existing = projections.first(where: { $0.resource == id }) {
            try claimCompletedMaterializationIfNeeded(id, projection: existing)
            if focus { focusProjection?(existing) }
            return (existing, true)
        }
        guard let provider = providers[id.machine] else { throw SurfaceCatalogError.noProvider(id.machine) }

        if reuseExisting {
            let waiterID = UUID()
            let result = try await withTaskCancellationHandler {
                try await awaitMaterialization(
                    id: id,
                    resource: resource,
                    provider: provider,
                    destination: destination,
                    focus: focus,
                    waiterID: waiterID
                )
            } onCancel: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.cancelInFlightProjectWaiter(id, waiterID: waiterID)
                }
            }
            return try finalizeMaterializationWaiter(
                id: id,
                waiterID: waiterID,
                result: result,
                focus: focus
            )
        }

        let projection = try await provider.materialize(resource, at: destination, focus: focus)
        record(projection)
        return (projection, false)
    }

    private func awaitMaterialization(
        id: SurfaceResourceID,
        resource: SurfaceResource,
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

            if let inFlight = inFlightProjects[id], let completedProjection = inFlight.completedProjection {
                var completed = inFlight
                completed.pendingAcknowledgements.insert(waiterID)
                inFlightProjects[id] = completed
                continuation.resume(returning: (projection: completedProjection, reused: true))
                return
            }
            if let inFlight = inFlightProjects[id], inFlight.provider !== provider {
                cancelInFlightProject(id, error: SurfaceCatalogError.unknownResource(id))
            }
            if var inFlight = inFlightProjects[id] {
                inFlight.abandoned = false
                inFlight.abandonmentDeadlineTask?.cancel()
                inFlight.abandonmentDeadlineTask = nil
                inFlight.waiters[waiterID] = (reused: true, continuation: continuation)
                inFlightProjects[id] = inFlight
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
                    let projection = try await provider.materialize(resource, at: destination, focus: focus)
                    self?.finishInFlightProject(id, token: token, provider: provider, result: .success(projection))
                } catch {
                    self?.finishInFlightProject(id, token: token, provider: provider, result: .failure(error))
                }
            }
            inFlightProjects[id] = SurfaceProjectionMaterialization(
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
        _ id: SurfaceResourceID,
        token: UUID,
        provider: any SurfaceProvider,
        result: Result<SurfaceProjection, any Error>
    ) {
        guard var inFlight = inFlightProjects[id], inFlight.token == token else {
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
                inFlightProjects[id] = nil
                cleanupMaterialization(projection, from: inFlight.provider)
                return
            }
            guard resources[id] != nil else {
                inFlightProjects[id] = nil
                cleanupMaterialization(projection, from: inFlight.provider)
                resume(inFlight.waiters, throwing: SurfaceCatalogError.unknownResource(id))
                return
            }
            let returnedProjection: SurfaceProjection
            let ownsProjection: Bool
            if let existing = projections.first(where: { $0.resource == id }) {
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
            inFlight.completionCleanupTask = completedMaterializationCleanupTask(id: id, token: token)
            inFlightProjects[id] = inFlight
            for waiter in waiters.values {
                waiter.continuation.resume(
                    returning: (projection: returnedProjection, reused: ownsProjection ? waiter.reused : true)
                )
            }
            if waiters.isEmpty {
                discardUnclaimedMaterializationIfEmpty(id)
            }
        case .failure(let error):
            inFlightProjects[id] = nil
            resume(inFlight.waiters, throwing: error)
        }
    }

    /// Finish the caller side of a successful materialization as one actor-isolated operation.
    /// The cancellation check and acknowledgement share the same turn, so cancellation cannot
    /// leave a newly recorded pane ownerless between those two actions.
    private func finalizeMaterializationWaiter(
        id: SurfaceResourceID,
        waiterID: UUID,
        result: SurfaceProjectionMaterialization.Result,
        focus: Bool
    ) throws -> SurfaceProjectionMaterialization.Result {
        guard !Task.isCancelled else {
            cancelCompletedMaterialization(id, waiterID: waiterID)
            throw CancellationError()
        }
        guard resources[id] != nil else {
            cancelCompletedMaterialization(id, waiterID: waiterID)
            throw SurfaceCatalogError.unknownResource(id)
        }
        guard projections.contains(result.projection) else {
            cancelCompletedMaterialization(id, waiterID: waiterID)
            throw SurfaceCatalogError.unavailable(id, reason: "projection closed while opening")
        }
        acknowledgeMaterialization(id, waiterID: waiterID)
        if result.reused, focus { focusProjection?(result.projection) }
        return result
    }

    private func acknowledgeMaterialization(_ id: SurfaceResourceID, waiterID: UUID) {
        guard let inFlight = inFlightProjects[id], inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.contains(waiterID) else { return }
        // One accepted result gives the pane an owner. The other resumed callers no longer need
        // bookkeeping because their later cancellation must not close a pane this caller owns.
        inFlight.completionCleanupTask?.cancel()
        inFlightProjects[id] = nil
    }

    private func claimCompletedMaterializationIfNeeded(
        _ id: SurfaceResourceID,
        projection: SurfaceProjection
    ) throws {
        guard let inFlight = inFlightProjects[id],
              let completedProjection = inFlight.completedProjection,
              completedProjection.resource == projection.resource,
              completedProjection.panelID == projection.panelID else { return }
        guard !Task.isCancelled else { throw CancellationError() }
        inFlight.completionCleanupTask?.cancel()
        inFlightProjects[id] = nil
    }

    private func cancelCompletedMaterialization(_ id: SurfaceResourceID, waiterID: UUID) {
        guard var inFlight = inFlightProjects[id],
              inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.remove(waiterID) != nil else { return }
        if inFlight.pendingAcknowledgements.isEmpty {
            inFlightProjects[id] = nil
            inFlight.completionCleanupTask?.cancel()
            if inFlight.completionOwnsProjection {
                cleanupRecordedMaterialization(inFlight)
            }
        } else {
            inFlightProjects[id] = inFlight
        }
    }

    /// Handles the defensive empty-set case without retaining a completed operation. Normal
    /// provider completions always have at least one waiter unless every caller cancelled first.
    private func discardUnclaimedMaterializationIfEmpty(_ id: SurfaceResourceID) {
        guard let inFlight = inFlightProjects[id],
              inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.isEmpty else { return }
        inFlightProjects[id] = nil
        inFlight.completionCleanupTask?.cancel()
        if inFlight.completionOwnsProjection {
            cleanupRecordedMaterialization(inFlight)
        }
    }

    private func completedMaterializationCleanupTask(id: SurfaceResourceID, token: UUID) -> Task<Void, Never> {
        let timeout = completedMaterializationRetention
        let clock = materializationClock
        return Task { [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expireCompletedMaterialization(id, token: token)
        }
    }

    /// A caller can be dropped without cancellation, so completion bookkeeping needs a bounded
    /// recovery path. An acknowledged result is removed before this deadline; otherwise the
    /// operation is treated as unclaimed and any pane owned by it is discarded.
    private func expireCompletedMaterialization(_ id: SurfaceResourceID, token: UUID) {
        guard let inFlight = inFlightProjects[id],
              inFlight.token == token,
              inFlight.completedProjection != nil,
              !inFlight.pendingAcknowledgements.isEmpty else { return }
        inFlightProjects[id] = nil
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

    private func cancelInFlightProjectWaiter(_ id: SurfaceResourceID, waiterID: UUID) {
        guard let current = inFlightProjects[id] else { return }
        if current.completedProjection != nil {
            cancelCompletedMaterialization(id, waiterID: waiterID)
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
            inFlight.abandonmentDeadlineTask = Task { [weak self, clock] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.expireAbandonedMaterialization(id, token: token)
            }
        }
        inFlightProjects[id] = inFlight
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Retire a detached provider operation after its bounded recovery window. New callers can
    /// start a fresh operation immediately while the old task drains cooperatively.
    private func expireAbandonedMaterialization(_ id: SurfaceResourceID, token: UUID) {
        guard let inFlight = inFlightProjects[id],
              inFlight.token == token,
              inFlight.completedProjection == nil,
              inFlight.abandoned,
              inFlight.waiters.isEmpty else { return }
        inFlightProjects[id] = nil
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
        let evictionTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.evictRetiredMaterialization(token)
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

    private func cancelInFlightProject(_ id: SurfaceResourceID, error: any Error) {
        guard let current = inFlightProjects[id], current.completedProjection == nil,
              let inFlight = inFlightProjects.removeValue(forKey: id) else { return }
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

    /// Record a pane that shows a resource (materialized by a provider, or adopted from an
    /// existing pane such as a local terminal the app created on its own).
    func record(_ projection: SurfaceProjection) {
        insertSupersedingLocalPlaceholder(projection)
        notifyChange()
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
            }
        }
        projections.insert(projection)
    }

    /// A pane went away (closed, or its workspace closed). Remote resources live on.
    func endProjections(panelID: UUID) {
        let ended = projections.filter { $0.panelID == panelID }
        guard !ended.isEmpty else { return }
        projections.subtract(ended)
        for projection in ended {
            providers[projection.resource.machine]?.projectionDidEnd(projection)
        }
        notifyChange()
    }

    /// A pane moved to another workspace (tab transfer / drag between windows).
    func moveProjections(panelID: UUID, to workspaceID: UUID) {
        let moved = projections.filter { $0.panelID == panelID }
        guard !moved.isEmpty else { return }
        projections.subtract(moved)
        for var projection in moved {
            projection.workspaceID = workspaceID
            projections.insert(projection)
        }
        notifyChange()
    }

    func projections(of id: SurfaceResourceID) -> [SurfaceProjection] {
        projections.filter { $0.resource == id }.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    func projection(forPanel panelID: UUID) -> SurfaceProjection? {
        projections.first { $0.panelID == panelID }
    }

    func resource(forPanel panelID: UUID) -> SurfaceResource? {
        projection(forPanel: panelID).flatMap { resources[$0.resource] }
    }

    // MARK: Restore

    /// Records persisted projections for panes the session restore recreated. The projection
    /// becomes live as soon as the provider reports the resource again (a cloud terminal
    /// after the link reconnects); local resources are re-registered by the local provider
    /// with the same panel-derived key, so they resolve immediately.
    func restore(_ records: [SurfaceProjectionRecord], workspaceID: UUID) {
        for record in records {
            if resources[record.resource] != nil {
                insertSupersedingLocalPlaceholder(SurfaceProjection(resource: record.resource, workspaceID: workspaceID, panelID: record.panelID))
            } else {
                pendingRestoredProjections[record] = workspaceID
            }
        }
        notifyChange()
    }

    func projectionRecords(forWorkspace workspaceID: UUID) -> [SurfaceProjectionRecord] {
        projections
            .filter { $0.workspaceID == workspaceID }
            .map { SurfaceProjectionRecord(panelID: $0.panelID, resource: $0.resource) }
            .sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    private func resolvePendingRestoredProjections(on machine: SurfaceMachineID) {
        for (record, workspaceID) in pendingRestoredProjections where record.resource.machine == machine {
            guard resources[record.resource] != nil else { continue }
            insertSupersedingLocalPlaceholder(SurfaceProjection(resource: record.resource, workspaceID: workspaceID, panelID: record.panelID))
            pendingRestoredProjections[record] = nil
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
