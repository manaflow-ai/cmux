import CmuxTerminalBackend
import Foundation

/// Consumes daemon snapshots and makes them the only live terminal topology authority.
@MainActor
final class TerminalBackendTopologyCoordinator {
    typealias SnapshotSource = @Sendable () async throws -> AsyncStream<TopologySnapshot>
    typealias FailureReporter = @MainActor (String?) -> Void

    private let snapshotSource: SnapshotSource
    private let projector: any TerminalBackendTopologyProjecting
    private let authorizationGate: TerminalBackendTopologyAuthorizationGate
    private let failureReporter: FailureReporter

    private var observationTask: Task<Void, Never>?
    private var latestSnapshot: TopologySnapshot?
    private var installedAuthority: BackendAuthority?
    private var installedRevision: UInt64?
    private var startupRestoreFinished = false
    private var expectedLegacyPlacements: Set<TerminalBackendTopologyPlacement>?

    init(
        snapshotSource: @escaping SnapshotSource,
        projector: any TerminalBackendTopologyProjecting,
        authorizationGate: TerminalBackendTopologyAuthorizationGate,
        failureReporter: @escaping FailureReporter = { _ in }
    ) {
        self.snapshotSource = snapshotSource
        self.projector = projector
        self.authorizationGate = authorizationGate
        self.failureReporter = failureReporter
    }

    convenience init?(
        composition: TerminalClientComposition,
        projector: any TerminalBackendTopologyProjecting,
        failureReporter: @escaping FailureReporter = { _ in }
    ) {
        guard let authorizationGate = composition.terminalBackendTopologyAuthorizationGate else {
            return nil
        }
        self.init(
            snapshotSource: {
                guard let snapshots = try await composition.canonicalSnapshots() else {
                    throw TerminalBackendClientError.disabled
                }
                return snapshots
            },
            projector: projector,
            authorizationGate: authorizationGate,
            failureReporter: failureReporter
        )
    }

    deinit {
        observationTask?.cancel()
    }

    func start() {
        guard observationTask == nil else { return }
        let snapshotSource = snapshotSource
        observationTask = Task { [weak self] in
            do {
                let snapshots = try await snapshotSource()
                for await snapshot in snapshots {
                    guard let self else { return }
                    try await self.receive(snapshot)
                }
                try Task.checkCancellation()
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

    /// Called after Swift's startup snapshot has restored client-owned browser/native panels.
    func startupRestoreDidFinish() {
        guard !startupRestoreFinished else { return }
        startupRestoreFinished = true
        do {
            try reconcileLatestSnapshot()
        } catch {
            fail(localizedFailure(for: error))
        }
    }

    var debugInstalledRevision: UInt64? {
        installedRevision
    }

    var debugExpectedLegacyPlacements: Set<TerminalBackendTopologyPlacement>? {
        expectedLegacyPlacements
    }

    private func receive(_ snapshot: TopologySnapshot) async throws {
        if let latestSnapshot,
           latestSnapshot.authority == snapshot.authority,
           snapshot.revision <= latestSnapshot.revision {
            return
        }

        if latestSnapshot?.authority != snapshot.authority {
            expectedLegacyPlacements = nil
            installedAuthority = nil
            installedRevision = nil
        }
        latestSnapshot = snapshot
        try reconcileLatestSnapshot()
    }

    private func reconcileLatestSnapshot() throws {
        guard let snapshot = latestSnapshot else { return }
        let plan = try TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
        // Swift session restore is the only source of client-owned browser/native
        // overlays. Wait until it is complete, then let the daemon snapshot win
        // for every terminal placement in one projection.
        guard startupRestoreFinished else { return }

        if let expectedLegacyPlacements {
            guard expectedLegacyPlacements.isSubset(of: plan.placements) else {
                return
            }
            self.expectedLegacyPlacements = nil
            try install(snapshot, plan: plan)
            return
        }

        if !plan.placements.isEmpty {
            try install(snapshot, plan: plan)
            return
        }

        let legacyPlacements = projector.legacyTerminalPlacements()
        guard !legacyPlacements.isEmpty else {
            try install(snapshot, plan: plan)
            return
        }
        expectedLegacyPlacements = legacyPlacements
        Task { await authorizationGate.authorize(legacyPlacements) }
    }

    private func install(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan
    ) throws {
        if installedAuthority == snapshot.authority,
           let installedRevision,
           snapshot.revision <= installedRevision {
            return
        }
        try projector.installCanonicalTopology(snapshot)
        installedAuthority = snapshot.authority
        installedRevision = snapshot.revision
        failureReporter(nil)
        Task { await authorizationGate.authorize(plan.placements) }
    }

    private func fail(_ message: String?) {
        failureReporter(message)
        Task { await authorizationGate.fail() }
    }

    private func localizedFailure(for error: any Error) -> String {
        switch error {
        case TerminalBackendTopologyProjectionError.multipleScreens(_, let count):
            String(
                localized: "terminalBackend.topology.multipleScreens",
                defaultValue: "This backend workspace contains \(count) screens. The current Swift shell can project exactly one screen per workspace, so the layout was left unchanged."
            )
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
}
