import CmuxNextServer
import CmuxNextServerHelper
import Foundation

/// A health check's one-click fix through the privileged helper (not implemented yet).
struct ServerHealthFixer {
    typealias Run = @MainActor (_ fix: ServerFix, _ revert: Bool) async throws(ServerHelperClient.Failure) -> Void

    let run: Run

    func fix(_ check: HealthCheckID) async -> String? { nil }

    static func reject(for failure: ServerHelperClient.Failure) -> String { "" }
}
