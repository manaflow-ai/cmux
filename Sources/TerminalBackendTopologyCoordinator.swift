import CmuxTerminalBackend
import Foundation

/// Consumes daemon snapshots and makes them the only live terminal topology authority.
@MainActor
final class TerminalBackendTopologyCoordinator {
    typealias SnapshotSource = @Sendable () async throws -> AsyncStream<TopologySnapshot>
    typealias EventSource = @Sendable () async throws -> AsyncStream<TerminalBackendTopologyStreamEvent>
    typealias PlanBuilder = @Sendable (
        CanonicalTopology
    ) async throws -> TerminalBackendTopologyProjectionPlan
    typealias ActivitySource = @Sendable () async -> AsyncStream<BackendTerminalActivitySnapshot>?
    typealias ActivityReporter = @MainActor (Set<UUID>) -> Void
    typealias FailureReporter = @MainActor (String?) -> Void
    typealias DisconnectHandler = @MainActor () -> Void

    private let eventSource: EventSource
    private let projector: any TerminalBackendTopologyProjecting
    private let authorizationGate: TerminalBackendTopologyAuthorizationGate
    private let planBuilder: PlanBuilder
    private let activitySource: ActivitySource?
    private let activityReporter: ActivityReporter
    private let failureReporter: FailureReporter
    private let mutationCoordinator: TerminalBackendTopologyMutationCoordinator?
    private let disconnectHandler: DisconnectHandler
    private let nativeBrowserRuntimeCoordinator: TerminalBackendNativeBrowserRuntimeCoordinator?
    private let remoteTmuxSurfaceRegistry: TerminalBackendRemoteTmuxSurfaceRegistry?

    private var observationTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var latestSnapshot: TopologySnapshot?
    private var installedAuthority: BackendAuthority?
    private var installedRevision: UInt64?
    private var installedAuthorizationToken: UUID?
    private var snapshotGeneration: UInt64 = 0
    private var admissionEpoch: UInt64
    private var startupRestoreFinished = false
    private var expectedLegacyPlacements: Set<TerminalBackendTopologyPlacement>?
    private var expectedLegacyGeneration: UInt64?
    private var legacyAuthorizationToken: UUID?
    private var latestActivitySnapshot: BackendTerminalActivitySnapshot?
    private var surfaceWorkspaceIDs: [SurfaceID: UUID] = [:]

    init(
        snapshotSource: @escaping SnapshotSource,
        projector: any TerminalBackendTopologyProjecting,
        authorizationGate: TerminalBackendTopologyAuthorizationGate,
        planBuilder: @escaping PlanBuilder = { topology in
            try await TerminalBackendTopologyCoordinator.detachedPlanBuilder(topology: topology)
        },
        activitySource: ActivitySource? = nil,
        activityReporter: @escaping ActivityReporter = { _ in },
        failureReporter: @escaping FailureReporter = { _ in },
        mutationCoordinator: TerminalBackendTopologyMutationCoordinator? = nil,
        disconnectHandler: @escaping DisconnectHandler = {},
        nativeBrowserRuntimeCoordinator: TerminalBackendNativeBrowserRuntimeCoordinator? = nil,
        remoteTmuxSurfaceRegistry: TerminalBackendRemoteTmuxSurfaceRegistry? = nil
    ) {
        self.eventSource = {
            let snapshots = try await snapshotSource()
            return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
                let task = Task {
                    for await snapshot in snapshots {
                        guard !Task.isCancelled else { break }
                        continuation.yield(.snapshot(snapshot))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        self.projector = projector
        self.authorizationGate = authorizationGate
        self.admissionEpoch = authorizationGate.currentAdmissionEpoch
        self.planBuilder = planBuilder
        self.activitySource = activitySource
        self.activityReporter = activityReporter
        self.failureReporter = failureReporter
        self.mutationCoordinator = mutationCoordinator
        self.disconnectHandler = disconnectHandler
        self.nativeBrowserRuntimeCoordinator = nativeBrowserRuntimeCoordinator
        self.remoteTmuxSurfaceRegistry = remoteTmuxSurfaceRegistry
    }

    init(
        eventSource: @escaping EventSource,
        projector: any TerminalBackendTopologyProjecting,
        authorizationGate: TerminalBackendTopologyAuthorizationGate,
        planBuilder: @escaping PlanBuilder = { topology in
            try await TerminalBackendTopologyCoordinator.detachedPlanBuilder(topology: topology)
        },
        activitySource: ActivitySource? = nil,
        activityReporter: @escaping ActivityReporter = { _ in },
        failureReporter: @escaping FailureReporter = { _ in },
        mutationCoordinator: TerminalBackendTopologyMutationCoordinator? = nil,
        disconnectHandler: @escaping DisconnectHandler = {},
        nativeBrowserRuntimeCoordinator: TerminalBackendNativeBrowserRuntimeCoordinator? = nil,
        remoteTmuxSurfaceRegistry: TerminalBackendRemoteTmuxSurfaceRegistry? = nil
    ) {
        self.eventSource = eventSource
        self.projector = projector
        self.authorizationGate = authorizationGate
        self.admissionEpoch = authorizationGate.currentAdmissionEpoch
        self.planBuilder = planBuilder
        self.activitySource = activitySource
        self.activityReporter = activityReporter
        self.failureReporter = failureReporter
        self.mutationCoordinator = mutationCoordinator
        self.disconnectHandler = disconnectHandler
        self.nativeBrowserRuntimeCoordinator = nativeBrowserRuntimeCoordinator
        self.remoteTmuxSurfaceRegistry = remoteTmuxSurfaceRegistry
    }

    convenience init?(
        composition: TerminalClientComposition,
        projector: any TerminalBackendTopologyProjecting,
        activityReporter: @escaping ActivityReporter = { _ in },
        failureReporter: @escaping FailureReporter = { _ in }
    ) {
        guard let authorizationGate = composition.terminalBackendTopologyAuthorizationGate else {
            return nil
        }
        self.init(
            eventSource: {
                guard let events = try await composition.canonicalTopologyEvents() else {
                    throw TerminalBackendClientError.disabled
                }
                return events
            },
            projector: projector,
            authorizationGate: authorizationGate,
            planBuilder: { topology in
                try await Self.detachedPlanBuilder(topology: topology)
            },
            activitySource: {
                await composition.terminalActivitySnapshots()
            },
            activityReporter: activityReporter,
            failureReporter: failureReporter,
            mutationCoordinator: composition.terminalBackendTopologyMutationCoordinator,
            disconnectHandler: {
                if let runtimeCoordinator = composition.nativeBrowserRuntimeCoordinator {
                    runtimeCoordinator.backendDidDisconnect()
                } else {
                    composition.nativeBrowserPresentationRegistry.removeAll()
                }
                composition.remoteTmuxSurfaceRegistry?.backendDidDisconnect()
            },
            nativeBrowserRuntimeCoordinator: composition.nativeBrowserRuntimeCoordinator,
            remoteTmuxSurfaceRegistry: composition.remoteTmuxSurfaceRegistry
        )
    }

    deinit {
        observationTask?.cancel()
        activityTask?.cancel()
        reconciliationTask?.cancel()
    }

    func start() {
        guard observationTask == nil else { return }
        startActivityObservation()
        let eventSource = eventSource
        observationTask = Task { [weak self] in
            do {
                let events = try await eventSource()
                for await event in events {
                    guard let self else { return }
                    await self.receive(event)
                }
                try Task.checkCancellation()
                self?.reconciliationTask?.cancel()
                self?.fail(
                    String(
                        localized: "terminalBackend.topology.streamEnded",
                        defaultValue: "The terminal backend stopped publishing layout state. Existing terminals remain in the backend, but cmux cannot safely change their layout."
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                self?.fail(self?.localizedFailure(for: error))
            }
        }
    }

    private func startActivityObservation() {
        guard activityTask == nil, let activitySource else { return }
        activityTask = Task { [weak self] in
            guard let snapshots = await activitySource() else { return }
            for await snapshot in snapshots {
                guard let self, !Task.isCancelled else { return }
                self.latestActivitySnapshot = snapshot
                self.publishActivityProjection()
            }
        }
    }

    /// Called after Swift's startup snapshot has restored client-owned browser/native panels.
    func startupRestoreDidFinish() {
        guard !startupRestoreFinished else { return }
        startupRestoreFinished = true
        scheduleReconciliation()
    }

    /// Reconciles the latest daemon value after a Swift window presentation is
    /// registered or removed. The registry owns workspace-to-window placement.
    func projectorsDidChange() {
        advanceAdmissionEpoch()
        snapshotGeneration &+= 1
        let authorityToRevoke = installedAuthority
        let revisionToRevoke = installedRevision
        let tokenToRevoke = installedAuthorizationToken
        installedAuthority = nil
        installedRevision = nil
        installedAuthorizationToken = nil
        if let authorityToRevoke, let revisionToRevoke, let tokenToRevoke {
            Task { [authorizationGate] in
                await authorizationGate.revoke(
                    authority: authorityToRevoke,
                    revision: revisionToRevoke,
                    token: tokenToRevoke
                )
            }
        }
        guard startupRestoreFinished else { return }
        scheduleReconciliation()
    }

    var debugInstalledRevision: UInt64? {
        installedRevision
    }

    var debugExpectedLegacyPlacements: Set<TerminalBackendTopologyPlacement>? {
        expectedLegacyPlacements
    }

    private func receive(_ event: TerminalBackendTopologyStreamEvent) async {
        switch event {
        case .snapshot(let snapshot):
            await receive(snapshot)
        case .delta(let delta):
            await receive(TopologySnapshot(
                authority: delta.authority,
                revision: delta.revision,
                topology: delta.replacement
            ))
        case .disconnected(let authority):
            guard (latestSnapshot?.authority ?? installedAuthority) == authority else { return }
            disconnectHandler()
            mutationCoordinator?.authorityDidDisconnect(authority)
            advanceAdmissionEpoch()
            let installedRevisionToRevoke = installedAuthority == authority
                ? installedRevision
                : nil
            let installedTokenToRevoke = installedAuthority == authority
                ? installedAuthorizationToken
                : nil
            let hadLegacyAuthorization = installedAuthority == nil
                && expectedLegacyPlacements != nil
            let legacyTokenToRevoke = legacyAuthorizationToken
            latestSnapshot = nil
            snapshotGeneration &+= 1
            reconciliationTask?.cancel()
            reconciliationTask = nil
            expectedLegacyPlacements = nil
            expectedLegacyGeneration = nil
            legacyAuthorizationToken = nil
            installedAuthority = nil
            installedRevision = nil
            installedAuthorizationToken = nil
            if let installedRevisionToRevoke {
                if let installedTokenToRevoke {
                    await authorizationGate.revoke(
                        authority: authority,
                        revision: installedRevisionToRevoke,
                        token: installedTokenToRevoke
                    )
                } else {
                    await authorizationGate.revoke(
                        authority: authority,
                        revision: installedRevisionToRevoke
                    )
                }
            } else if hadLegacyAuthorization {
                if let legacyTokenToRevoke {
                    await authorizationGate.revokeLegacyAuthorization(token: legacyTokenToRevoke)
                } else {
                    await authorizationGate.revokeLegacyAuthorization()
                }
            }
            failureReporter(String(
                localized: "terminalBackend.topology.disconnected",
                defaultValue: "The terminal backend connection is recovering. Existing terminals remain in the backend, but layout changes are paused until a fresh snapshot arrives."
            ))
        }
    }

    private func receive(_ snapshot: TopologySnapshot) async {
        if let latestSnapshot,
           latestSnapshot.authority == snapshot.authority,
           snapshot.revision <= latestSnapshot.revision {
            return
        }

        if let previousAuthority = latestSnapshot?.authority ?? installedAuthority,
           previousAuthority != snapshot.authority {
            disconnectHandler()
            mutationCoordinator?.authorityDidDisconnect(previousAuthority)
        }

        // Invalidate old placement admission synchronously before any actor
        // revoke or asynchronous planning can yield.
        advanceAdmissionEpoch()

        if latestSnapshot?.authority != snapshot.authority {
            let legacyTokenToRevoke = legacyAuthorizationToken
            let installedTokenToRevoke = installedAuthorizationToken
            if let installedAuthority, let installedRevision {
                if let installedTokenToRevoke {
                    await authorizationGate.revoke(
                        authority: installedAuthority,
                        revision: installedRevision,
                        token: installedTokenToRevoke
                    )
                } else {
                    await authorizationGate.revoke(
                        authority: installedAuthority,
                        revision: installedRevision
                    )
                }
            } else if expectedLegacyPlacements != nil {
                if let legacyTokenToRevoke {
                    await authorizationGate.revokeLegacyAuthorization(token: legacyTokenToRevoke)
                } else {
                    await authorizationGate.revokeLegacyAuthorization()
                }
            }
            expectedLegacyPlacements = nil
            expectedLegacyGeneration = nil
            legacyAuthorizationToken = nil
            installedAuthority = nil
            installedRevision = nil
            installedAuthorizationToken = nil
        }
        snapshotGeneration &+= 1
        latestSnapshot = snapshot
        scheduleReconciliation()
    }

    private func scheduleReconciliation() {
        reconciliationTask?.cancel()
        guard startupRestoreFinished, latestSnapshot != nil else {
            reconciliationTask = nil
            return
        }
        let generation = snapshotGeneration
        let admissionEpoch = admissionEpoch
        reconciliationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.reconcileLatestSnapshot(
                    generation: generation,
                    admissionEpoch: admissionEpoch
                )
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.snapshotGeneration else { return }
                await self.rejectCurrentProjection(error)
            }
        }
    }

    private func reconcileLatestSnapshot(
        generation: UInt64,
        admissionEpoch: UInt64
    ) async throws {
        guard let snapshot = latestSnapshot else { return }
        // Client-owned browser/native restoration must finish before planning;
        // there is no useful projection work to cache before that boundary.
        guard startupRestoreFinished else { return }
        let plan: TerminalBackendTopologyProjectionPlan
        do {
            let structuralPlan = try await planBuilder(snapshot.topology)
            guard isCurrent(
                snapshot,
                generation: generation,
                admissionEpoch: admissionEpoch
            ) else { return }
            surfaceWorkspaceIDs = structuralPlan.surfaceWorkspaceIDs
            publishActivityProjection()
            if let remoteTmuxSurfaceRegistry {
                try await remoteTmuxSurfaceRegistry.claimBeforeProjection(
                    authority: snapshot.authority,
                    plan: structuralPlan
                )
                guard isCurrent(
                    snapshot,
                    generation: generation,
                    admissionEpoch: admissionEpoch
                ) else { return }
            }
            plan = try projector.resolvePresentationPlan(structuralPlan)
        } catch {
            guard isCurrent(
                snapshot,
                generation: generation,
                admissionEpoch: admissionEpoch
            ) else { return }
            throw error
        }
        guard isCurrent(
            snapshot,
            generation: generation,
            admissionEpoch: admissionEpoch
        ) else { return }
        if let nativeBrowserRuntimeCoordinator {
            try await nativeBrowserRuntimeCoordinator.claimBeforeProjection(
                authority: snapshot.authority,
                surfaceIDs: plan.frontendNativeBrowserSurfaceIDs,
                projector: projector
            )
            guard isCurrent(
                snapshot,
                generation: generation,
                admissionEpoch: admissionEpoch
            ) else { return }
        }
        if let expectedLegacyPlacements,
           expectedLegacyGeneration == generation {
            guard expectedLegacyPlacements.isSubset(of: plan.placements) else {
                return
            }
            self.expectedLegacyPlacements = nil
            expectedLegacyGeneration = nil
            try await install(
                snapshot,
                plan: plan,
                generation: generation,
                admissionEpoch: admissionEpoch
            )
            return
        }
        if expectedLegacyPlacements != nil {
            let staleToken = legacyAuthorizationToken
            self.expectedLegacyPlacements = nil
            expectedLegacyGeneration = nil
            legacyAuthorizationToken = nil
            if let staleToken {
                await authorizationGate.revokeLegacyAuthorization(token: staleToken)
            }
            guard isCurrent(
                snapshot,
                generation: generation,
                admissionEpoch: admissionEpoch
            ) else { return }
        }

        // A browser-only canonical topology is still nonempty daemon state.
        // `placements` intentionally contains only materialized PTYs.
        if !plan.workspaces.isEmpty {
            try await install(
                snapshot,
                plan: plan,
                generation: generation,
                admissionEpoch: admissionEpoch
            )
            return
        }

        let legacyPlacements = projector.legacyTerminalPlacements()
        guard !legacyPlacements.isEmpty else {
            try await install(
                snapshot,
                plan: plan,
                generation: generation,
                admissionEpoch: admissionEpoch
            )
            return
        }
        try Task.checkCancellation()
        guard isCurrent(
            snapshot,
            generation: generation,
            admissionEpoch: admissionEpoch
        ) else { return }
        expectedLegacyPlacements = legacyPlacements
        expectedLegacyGeneration = generation
        guard let legacyToken = await authorizationGate.authorize(
            legacyPlacements,
            admissionEpoch: admissionEpoch
        ) else {
            return
        }
        legacyAuthorizationToken = legacyToken
        guard isCurrent(
            snapshot,
            generation: generation,
            admissionEpoch: admissionEpoch
        ) else {
            if expectedLegacyGeneration == generation {
                expectedLegacyPlacements = nil
                expectedLegacyGeneration = nil
            }
            if legacyAuthorizationToken == legacyToken {
                legacyAuthorizationToken = nil
            }
            await authorizationGate.revokeLegacyAuthorization(token: legacyToken)
            if latestSnapshot != nil {
                scheduleReconciliation()
            }
            return
        }
    }

    private func install(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan,
        generation: UInt64,
        admissionEpoch: UInt64
    ) async throws {
        try Task.checkCancellation()
        guard isCurrent(
            snapshot,
            generation: generation,
            admissionEpoch: admissionEpoch
        ) else { return }
        if installedAuthority == snapshot.authority,
           let installedRevision,
           snapshot.revision <= installedRevision {
            return
        }
        try projector.installCanonicalTopology(snapshot, plan: plan)
        nativeBrowserRuntimeCoordinator?.projectionDidInstall(
            surfaceIDs: plan.frontendNativeBrowserSurfaceIDs,
            projector: projector
        )
        remoteTmuxSurfaceRegistry?.projectionDidInstall(
            plan: plan,
            projector: projector
        )
        guard isCurrent(
            snapshot,
            generation: generation,
            admissionEpoch: admissionEpoch
        ) else { return }
        let legacyTokenReplacedByCanonicalAuthorization = legacyAuthorizationToken
        guard let authorizationToken = await authorizationGate.authorize(
            authority: snapshot.authority,
            revision: snapshot.revision,
            placements: plan.placements,
            admissionEpoch: admissionEpoch
        ) else {
            return
        }
        if legacyAuthorizationToken == legacyTokenReplacedByCanonicalAuthorization {
            legacyAuthorizationToken = nil
        }
        guard isCurrent(
            snapshot,
            generation: generation,
            admissionEpoch: admissionEpoch
        ) else {
            await authorizationGate.revoke(
                authority: snapshot.authority,
                revision: snapshot.revision,
                token: authorizationToken
            )
            return
        }
        installedAuthority = snapshot.authority
        installedRevision = snapshot.revision
        installedAuthorizationToken = authorizationToken
        failureReporter(nil)
    }

    private func publishActivityProjection() {
        guard let latestActivitySnapshot else { return }
        let unreadWorkspaceIDs: Set<UUID> = Set(latestActivitySnapshot.facts.compactMap { fact -> UUID? in
            guard latestActivitySnapshot.isUnread(surfaceID: fact.surfaceID) else {
                return nil
            }
            return surfaceWorkspaceIDs[fact.surfaceID]
        })
        activityReporter(unreadWorkspaceIDs)
    }

    private func rejectCurrentProjection(_ error: any Error) async {
        advanceAdmissionEpoch()
        snapshotGeneration &+= 1
        failureReporter(localizedFailure(for: error))
        let authorityToRevoke = installedAuthority
        let revisionToRevoke = installedRevision
        let tokenToRevoke = installedAuthorizationToken
        let legacyTokenToRevoke = legacyAuthorizationToken
        installedAuthority = nil
        installedRevision = nil
        installedAuthorizationToken = nil
        expectedLegacyPlacements = nil
        expectedLegacyGeneration = nil
        legacyAuthorizationToken = nil
        if let authorityToRevoke, let revisionToRevoke {
            if let tokenToRevoke {
                await authorizationGate.revoke(
                    authority: authorityToRevoke,
                    revision: revisionToRevoke,
                    token: tokenToRevoke
                )
            } else {
                await authorizationGate.revoke(
                    authority: authorityToRevoke,
                    revision: revisionToRevoke
                )
            }
        }
        if let legacyTokenToRevoke {
            await authorizationGate.revokeLegacyAuthorization(token: legacyTokenToRevoke)
        }
    }

    private func isCurrent(
        _ snapshot: TopologySnapshot,
        generation: UInt64,
        admissionEpoch: UInt64
    ) -> Bool {
        guard generation == snapshotGeneration,
              admissionEpoch == self.admissionEpoch,
              authorizationGate.currentAdmissionEpoch == admissionEpoch,
              let latestSnapshot else { return false }
        return latestSnapshot.authority == snapshot.authority
            && latestSnapshot.revision == snapshot.revision
    }

    private func fail(_ message: String?) {
        disconnectHandler()
        if let authority = latestSnapshot?.authority ?? installedAuthority {
            mutationCoordinator?.authorityDidDisconnect(authority)
        }
        advanceAdmissionEpoch()
        snapshotGeneration &+= 1
        failureReporter(message)
        Task { await authorizationGate.fail() }
    }

    private func advanceAdmissionEpoch() {
        admissionEpoch = authorizationGate.advanceAdmissionEpoch()
    }

    private func localizedFailure(for error: any Error) -> String {
        switch error {
        case TerminalBackendTopologyProjectionError.unsupportedSurfaceKind(_, let kind):
            String(
                localized: "terminalBackend.topology.unsupportedSurfaceKind",
                defaultValue: "The backend published an unsupported panel endpoint (\(kind)). The layout was left unchanged so client-owned panels are not discarded."
            )
        default:
            String(
                localized: "terminalBackend.topology.projectionFailed",
                defaultValue: "cmux could not safely project the terminal backend layout. The local layout was left unchanged."
            )
        }
    }

    nonisolated private static func detachedPlanBuilder(
        topology: CanonicalTopology
    ) async throws -> TerminalBackendTopologyProjectionPlan {
        try await Task.detached(priority: .userInitiated) {
            try TerminalBackendTopologyProjectionPlan(topology: topology)
        }.value
    }
}
