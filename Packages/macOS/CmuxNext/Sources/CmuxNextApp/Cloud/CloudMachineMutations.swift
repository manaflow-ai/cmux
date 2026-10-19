import CmuxNextCloud
import CmuxNextDaemon

/// One mutation path for machine actions from the registry and its UI surfaces.
@MainActor
struct CloudMachineMutations {
    enum Mutation: Hashable, Sendable {
        case delete, pause, resume, rename(String)
    }
    let appServer: Bool
    let snapshot: @Sendable () async throws -> CloudTeamScope.Snapshot
    let ops: (CloudTeamScope.Snapshot) -> CloudAppOp
    let check: (CloudTeamScope.Snapshot) throws -> Void
    let legacy: @Sendable (Mutation, String) async throws -> Void

    func run(_ mutation: Mutation, machine: String, origin: CloudLinkOrigin,
             commit: () -> Void) async throws {
        try await legacy(mutation, machine)
        commit()
    }
}
