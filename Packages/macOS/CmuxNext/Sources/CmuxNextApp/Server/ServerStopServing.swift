import CmuxNextServerHelper
import Foundation
import ServiceManagement

/// One launchd job the app registered with `SMAppService`, as a seam.
struct ServerServiceRegistration {
    var status: @MainActor () -> SMAppService.Status
    var unregister: @MainActor () async throws -> Void

    static func agent(plistName: String) -> ServerServiceRegistration {
        ServerServiceRegistration(status: { SMAppService.agent(plistName: plistName).status },
                                  unregister: { try await SMAppService.agent(plistName: plistName).unregister() })
    }

    static func daemon(plistName: String) -> ServerServiceRegistration {
        ServerServiceRegistration(status: { SMAppService.daemon(plistName: plistName).status },
                                  unregister: { try await SMAppService.daemon(plistName: plistName).unregister() })
    }
}

/// `server.stopServing` (plans/cmux-next/server.md 4.4 and 9.4): puts back
/// every power setting a fix changed (the helper's revert restores the value
/// it recorded), then unregisters the server LaunchAgent and the privileged
/// helper. Idempotent: a job that is not registered is skipped, and a fix
/// with nothing recorded is not an error. When a revert fails, the helper
/// stays registered so the user can stop serving again and get the
/// settings back; the agent is still removed.
struct ServerStopServing {
    enum Failure: Error, Equatable {
        case revert(String)
        case unregister(String)

        var message: String {
            switch self {
            case let .revert(reason):
                RefusalStrings.format("refusal.server.revertFailed", "Could not restore your power settings: %@", reason)
            case let .unregister(reason):
                RefusalStrings.format("refusal.server.stopFailed", "Could not stop serving: %@", reason)
            }
        }
    }

    /// Nil when this build does not carry the job.
    var agent: ServerServiceRegistration?
    var helper: ServerServiceRegistration?
    var revert: @MainActor (ServerFix) async throws(ServerHelperClient.Failure) -> Void

    static func app() -> ServerStopServing {
        ServerStopServing(
            agent: ServerLaunchAgent.isBundled ? .agent(plistName: ServerLaunchAgent.plistName) : nil,
            helper: ServerHelperClient.isBundled ? .daemon(plistName: ServerHelperConstants().plistName) : nil,
            revert: { (fix: ServerFix) async throws(ServerHelperClient.Failure) in
                try await ServerHelperClient.run(fix, revert: true)
            })
    }

    func run() async throws(Failure) {
        var revertFailure: String?
        // Only an enabled helper can have applied a fix; reverting through
        // one that is not registered would register it.
        if let helper, helper.status() == .enabled {
            for fix in ServerFix.allCases {
                do throws(ServerHelperClient.Failure) {
                    try await revert(fix)
                } catch {
                    if case let .refused(reason) = error, reason == ServerHelperService.nothingToRevert { continue }
                    revertFailure = revertFailure ?? ServerHealthFixer.reject(for: error)
                }
            }
        }
        if let agent { try await unregister(agent) }
        if let revertFailure { throw .revert(revertFailure) }
        if let helper { try await unregister(helper) }
    }

    private func unregister(_ job: ServerServiceRegistration) async throws(Failure) {
        guard job.status() != .notRegistered else { return }
        do {
            try await job.unregister()
        } catch {
            throw .unregister(String(describing: error))
        }
    }
}
