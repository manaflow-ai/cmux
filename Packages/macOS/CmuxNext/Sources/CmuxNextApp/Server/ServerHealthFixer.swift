import CmuxNextServer
import CmuxNextServerHelper
import Foundation

/// A health check's one-click fix through the privileged helper
/// (plans/cmux-next/server.md 9.4). Only the allowlisted `ServerFix`es of
/// the check run, in allowlist order, and the first refusal stops the rest.
/// The caller is `LocalServerSource` for a user's Fix click; nothing else
/// starts a fix.
struct ServerHealthFixer {
    /// Applies (`revert` false) or reverts one fix.
    typealias Run = @MainActor (_ fix: ServerFix, _ revert: Bool) async throws(ServerHelperClient.Failure) -> Void

    let run: Run
    var gate: ServerFixGate = .shared

    /// The App's fixer: the helper of this build.
    static let helper = ServerHealthFixer { (fix: ServerFix, revert: Bool) async throws(ServerHelperClient.Failure) in
        try await ServerHelperClient.run(fix, revert: revert)
    }

    /// `sleep.enabled`: no system or disk sleep on AC, wake for network;
    /// `restart.noAutoRestart`: restart after a power failure. Other checks have none.
    static func fixes(for check: HealthCheckID) -> [ServerFix] {
        ServerFix.allCases.filter { $0.check == check.rawValue }
    }

    /// Runs the check's fixes; nil on success, else the refusal to show.
    func fix(_ check: HealthCheckID) async -> String? {
        let fixes = Self.fixes(for: check)
        guard !fixes.isEmpty else {
            return RefusalStrings.text("refusal.server.noFix", "This check has no automatic fix.")
        }
        for fix in fixes {
            do throws(ServerHelperClient.Failure) {
                try await run(fix, false)
            } catch {
                return Self.reject(for: error)
            }
        }
        return nil
    }

    /// Localized text for a helper failure; the helper's own reason is kept.
    static func reject(for failure: ServerHelperClient.Failure) -> String {
        switch failure {
        case .notInBuild:
            RefusalStrings.text("refusal.server.helperNotInBuild", "This build does not include the server helper.")
        case .unsigned:
            RefusalStrings.text("refusal.server.helperUnsigned", "Fixes need a signed cmux build.")
        case .requiresApproval:
            RefusalStrings.text("refusal.server.needsApproval", "Allow cmux in System Settings > Login Items, then try again.")
        case let .refused(reason):
            RefusalStrings.format("refusal.server.fixRefused", "The server helper refused the fix: %@", reason)
        case .timedOut:
            RefusalStrings.text("refusal.server.helperTimedOut", "The server helper did not answer. Try again.")
        case let .failed(reason):
            RefusalStrings.format("refusal.server.fixFailed", "Could not run the fix: %@", reason)
        }
    }
}
