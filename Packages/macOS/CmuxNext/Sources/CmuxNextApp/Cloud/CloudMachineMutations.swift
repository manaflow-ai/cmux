import CmuxNextCloud
import CmuxNextDaemon
import Foundation

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
        if appServer {
            let scope = try await snapshot()
            try check(scope)
            var args: [String: JSONValue] = ["machine": .string(machine)]
            let op: String
            switch mutation {
            case .delete: op = "cloud.machine.delete"
            case .pause: op = "cloud.machine.pause"
            case .resume: op = "cloud.machine.start"
            case .rename(let name):
                op = "cloud.machine.rename"
                // The canonical API requires a name. Clearing the custom label
                // restores this path's default title, the canonical machine id.
                args["name"] = .string(name.isEmpty ? machine : name)
            }
            _ = try await ops(scope)(op, .object(args), UUID().uuidString, origin == .user ? .user : .script)
            try await scope.recheck()
            try check(scope)
        } else {
            try await legacy(mutation, machine)
        }
        commit()
    }
}
