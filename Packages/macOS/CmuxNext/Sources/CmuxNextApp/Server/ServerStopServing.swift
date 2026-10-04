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
/// with nothing recorded is not an error. When a revert fails, or the
/// helper awaits approval in Login Items (it cannot run, and the app cannot
/// read what it recorded, so the values count as changed), the helper stays
/// registered so the user can stop serving again and get the settings back;
/// the agent is still removed. A running Fix finishes its current step
/// first (`ServerFixGate`), so no apply lands after its revert.
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
    var gate: ServerFixGate = .shared

    static func app() -> ServerStopServing {
        ServerStopServing(
            agent: ServerLaunchAgent.isBundled ? .agent(plistName: ServerLaunchAgent.plistName) : nil,
            helper: ServerHelperClient.isBundled ? .daemon(plistName: ServerHelperConstants().plistName) : nil,
            revert: { (fix: ServerFix) async throws(ServerHelperClient.Failure) in
                try await ServerHelperClient.run(fix, revert: true)
            })
    }

    func run() async throws(Failure) {
        await gate.acquire()
        let revertFailure = await revertAll()
        gate.release()
        if let agent { try await unregister(agent) }
        if let revertFailure { throw .revert(revertFailure) }
        if let helper { try await unregister(helper) }
    }

    /// Nil when every recorded value is back (or nothing ran), else the reason.
    private func revertAll() async -> String? {
        guard let helper else { return nil }
        switch helper.status() {
        case .enabled:
            var failure: String?
            for fix in ServerFix.allCases {
                do throws(ServerHelperClient.Failure) {
                    try await revert(fix)
                } catch {
                    if case let .refused(reason) = error, reason == ServerHelperService.nothingToRevert { continue }
                    failure = failure ?? ServerHealthFixer.reject(for: error)
                }
            }
            return failure
        case .requiresApproval:
            return ServerHealthFixer.reject(for: .requiresApproval)
        default:
            // Not registered or not in this build: no helper ever ran a fix.
            return nil
        }
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
