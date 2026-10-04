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

/// `server.stopServing` (not implemented yet; plans/cmux-next/server.md 4.4 and 9.4): puts back
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

    func run() async throws(Failure) {}
}
