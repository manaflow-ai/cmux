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

    static let didChangeNotification = Notification.Name("cmux.surfaces.didChange")

    private(set) var machines: [SurfaceMachineID: SurfaceMachineInfo] = [:]
    private(set) var resources: [SurfaceResourceID: SurfaceResource] = [:]
    private(set) var projections: Set<SurfaceProjection> = []
    private var providers: [SurfaceMachineID: any SurfaceProvider] = [:]
    /// Materializations are asynchronous, so actor reentrancy can otherwise let two callers
    /// pass the reuse check before either provider has returned a projection.
    private var inFlightProjects: [SurfaceResourceID: SurfaceProjectionMaterialization] = [:]
    /// Panels whose projection was recorded from a restored session before the provider
    /// re-synced; resolved into `projections` once the resource shows up.
    private var pendingRestoredProjections: [SurfaceProjectionRecord: UUID] = [:]

    /// Focus/select behavior the app uses to bring an existing projection forward.
    var focusProjection: ((SurfaceProjection) -> Void)?

    init() {}

    // MARK: Providers

    func register(_ provider: any SurfaceProvider) {
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
            try Task.checkCancellation()
            guard resources[id] != nil else { throw SurfaceCatalogError.unknownResource(id) }
            guard projections.contains(result.projection) else {
                throw SurfaceCatalogError.unavailable(id, reason: "projection closed while opening")
            }
            if result.reused, focus { focusProjection?(result.projection) }
            return result
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

            if var inFlight = inFlightProjects[id] {
                inFlight.waiters[waiterID] = (reused: true, continuation: continuation)
                inFlightProjects[id] = inFlight
                return
            }

            let token = UUID()
            let task = Task { @MainActor [weak self] in
                do {
                    let projection = try await provider.materialize(resource, at: destination, focus: focus)
                    guard !Task.isCancelled else { throw CancellationError() }
                    self?.finishInFlightProject(id, token: token, result: .success(projection))
                } catch {
                    self?.finishInFlightProject(id, token: token, result: .failure(error))
                }
            }
            inFlightProjects[id] = SurfaceProjectionMaterialization(
                token: token,
                task: task,
                waiters: [waiterID: (reused: false, continuation: continuation)]
            )
        }
    }

    private func finishInFlightProject(
        _ id: SurfaceResourceID,
        token: UUID,
        result: Result<SurfaceProjection, any Error>
    ) {
        guard let inFlight = inFlightProjects[id], inFlight.token == token else { return }
        inFlightProjects[id] = nil

        switch result {
        case .success(let projection):
            guard resources[id] != nil else {
                resume(inFlight.waiters, throwing: SurfaceCatalogError.unknownResource(id))
                return
            }
            record(projection)
            for waiter in inFlight.waiters.values {
                waiter.continuation.resume(returning: (projection: projection, reused: waiter.reused))
            }
        case .failure(let error):
            resume(inFlight.waiters, throwing: error)
        }
    }

    private func cancelInFlightProjectWaiter(_ id: SurfaceResourceID, waiterID: UUID) {
        guard var inFlight = inFlightProjects[id],
              let waiter = inFlight.waiters.removeValue(forKey: waiterID) else { return }
        if inFlight.waiters.isEmpty {
            inFlightProjects[id] = nil
            inFlight.task.cancel()
        } else {
            inFlightProjects[id] = inFlight
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelInFlightProject(_ id: SurfaceResourceID, error: any Error) {
        guard let inFlight = inFlightProjects.removeValue(forKey: id) else { return }
        inFlight.task.cancel()
        resume(inFlight.waiters, throwing: error)
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
