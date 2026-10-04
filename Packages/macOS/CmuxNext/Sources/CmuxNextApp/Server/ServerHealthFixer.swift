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
    typealias Run = @MainActor (_ fix: ServerFix, _ revert: Bool, _ willCall: @escaping @MainActor () async throws -> Void)
        async throws(ServerHelperClient.Failure) -> Void

    let run: Run
    /// Shared with Stop Serving, so a revert never overtakes an apply.
    var gate: ServerFixGate = .shared
    /// Every fix the helper applied, for Stop Serving.
    let ledger: ServerFixLedger

    /// The App's fixer: the helper of this build.
    static let helper = ServerHealthFixer(run: { (fix: ServerFix, revert: Bool, willCall: @escaping @MainActor () async throws -> Void)
        async throws(ServerHelperClient.Failure) in
        try await ServerHelperClient.run(fix, revert: revert, willCall: willCall)
    }, ledger: .standard)

    /// The Fix button for a check this app fixes itself: app text, never the
    /// server's title (the click runs the allowlist, not the server's words).
    static func localFix(for check: HealthCheckID) -> HealthFix? {
        switch check {
        case .sleepEnabled:
            HealthFix(title: String(localized: "server.fix.sleep", defaultValue: "Keep Awake on Power",
                                    table: "Server", bundle: .module), needsAdmin: true)
        case .noAutoRestart:
            HealthFix(title: String(localized: "server.fix.autoRestart", defaultValue: "Restart After Power Loss",
                                    table: "Server", bundle: .module), needsAdmin: true)
        default:
            nil
        }
    }

    /// `localFix` for every check with allowlisted fixes.
    static var localFixes: [HealthCheckID: HealthFix] {
        Dictionary(uniqueKeysWithValues: Set(ServerFix.allCases.map { HealthCheckID($0.check) }).compactMap { check in
            localFix(for: check).map { (check, $0) }
        })
    }

    /// `sleep.enabled`: no system or disk sleep on AC, wake for network;
    /// `restart.noAutoRestart`: restart after a power failure. Other checks have none.
    static func fixes(for check: HealthCheckID) -> [ServerFix] {
        ServerFix.allCases.filter { $0.check == check.rawValue }
    }

    /// Runs the check's fixes; nil on success, else the refusal to show.
    /// Holds the gate for the whole run and stops before the next fix once
    /// the caller is cancelled (Stop Serving hides the panel first).
    func fix(_ check: HealthCheckID) async -> String? {
        let fixes = Self.fixes(for: check)
        guard !fixes.isEmpty else {
            return RefusalStrings.text("refusal.server.noFix", "This check has no automatic fix.")
        }
        await gate.acquire()
        defer { gate.release() }
        for fix in fixes {
            guard !Task.isCancelled else { return Self.cancelled }
            // Recorded before the call: a call that ends early (timeout) may
            // still have changed the setting, and Stop Serving must revert it.
            // Without the record the fix does not run.
            do {
                try await ledger.record(fix)
            } catch {
                return RefusalStrings.format("refusal.server.fixFailed", "Could not run the fix: %@", String(describing: error))
            }
            do throws(ServerHelperClient.Failure) {
                try await run(fix, false) {}
            } catch {
                return Self.reject(for: error)
            }
        }
        return nil
    }

    /// A Fix cut short by Stop Serving: not a success.
    static var cancelled: String {
        RefusalStrings.text("refusal.server.fixCancelled", "The fix was stopped before it finished.")
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
