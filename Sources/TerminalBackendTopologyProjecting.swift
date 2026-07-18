import CmuxTerminalBackend
import Foundation

/// One prevalidated projection that supports process-wide all-or-nothing commit.
@MainActor
final class TerminalBackendTopologyPreparedProjection {
    private enum State: Equatable {
        case prepared
        case committed
        case finished
        case rolledBack
    }

    private let commitOperation: @MainActor () throws -> Void
    private let finalizeOperation: @MainActor () -> Void
    private let rollbackOperation: @MainActor () throws -> Void
    private var state: State = .prepared

    init(
        commit: @escaping @MainActor () throws -> Void,
        finalize: @escaping @MainActor () -> Void = {},
        rollback: @escaping @MainActor () throws -> Void
    ) {
        commitOperation = commit
        finalizeOperation = finalize
        rollbackOperation = rollback
    }

    func commit() throws {
        guard state == .prepared else { return }
        do {
            try commitOperation()
            state = .committed
        } catch let commitError {
            do {
                try rollbackOperation()
            } catch let rollbackError {
                state = .rolledBack
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "canonical topology rollback failed: \(rollbackError.localizedDescription)"
                )
            }
            state = .rolledBack
            throw commitError
        }
    }

    func finalize() {
        guard state == .committed else { return }
        finalizeOperation()
        state = .finished
    }

    func rollback() throws {
        guard state == .committed else { return }
        do {
            try rollbackOperation()
            state = .rolledBack
        } catch {
            state = .rolledBack
            throw error
        }
    }
}

/// Main-actor projection seam used by the stream coordinator and focused tests.
@MainActor
protocol TerminalBackendTopologyProjecting: AnyObject {
    func resolvePresentationPlan(
        _ plan: TerminalBackendTopologyProjectionPlan
    ) throws -> TerminalBackendTopologyProjectionPlan
    func presentationWorkspaceIDs() -> Set<UUID>
    func allPresentationPlacements() -> Set<TerminalBackendTopologyPlacement>
    func legacyTerminalPlacements() -> Set<TerminalBackendTopologyPlacement>
    func frontendNativeBrowserIsPresented(surfaceID: SurfaceID) -> Bool
    func frontendNativeBrowserSourceURL(surfaceID: SurfaceID) -> URL?
    func installFrontendNativeBrowserClaimSourceURL(
        _ sourceURL: URL,
        surfaceID: SurfaceID
    )
    /// Installs one daemon-claimed remote-tmux producer into the presentation
    /// that owns its canonical workspace. Returns true only for that owner.
    func restoreRemoteTmuxProducer(
        _ projection: TerminalBackendRemoteTmuxProducerProjection
    ) -> Bool
    func prepareCanonicalTopology(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan
    ) throws -> TerminalBackendTopologyPreparedProjection
}

extension TerminalBackendTopologyProjecting {
    func resolvePresentationPlan(
        _ plan: TerminalBackendTopologyProjectionPlan
    ) throws -> TerminalBackendTopologyProjectionPlan {
        plan
    }
    func allPresentationPlacements() -> Set<TerminalBackendTopologyPlacement> {
        legacyTerminalPlacements()
    }
    func frontendNativeBrowserSourceURL(surfaceID _: SurfaceID) -> URL? {
        nil
    }
    func frontendNativeBrowserIsPresented(surfaceID _: SurfaceID) -> Bool {
        false
    }
    func installFrontendNativeBrowserClaimSourceURL(
        _ sourceURL: URL,
        surfaceID: SurfaceID
    ) {}
    func restoreRemoteTmuxProducer(
        _ projection: TerminalBackendRemoteTmuxProducerProjection
    ) -> Bool {
        _ = projection
        return false
    }

    func installCanonicalTopology(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan
    ) throws {
        let prepared = try prepareCanonicalTopology(snapshot, plan: plan)
        try prepared.commit()
        prepared.finalize()
    }
}
