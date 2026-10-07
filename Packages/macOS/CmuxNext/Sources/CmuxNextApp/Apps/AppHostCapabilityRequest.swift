import CmuxNextApps
import Foundation

/// One app op that the Mac app owns (plans/cmux-next/app-platform.md
/// section 14, APP-R1): the in-app prototype engine calls these handlers
/// today; the daemon's provider channel (`apps-provider-request`) calls the
/// same handlers once routing lands. Only the caller changes.
nonisolated struct AppHostCapabilityRequest: Sendable {
    /// The calling app (`cmux/coderouter`).
    var app: String
    var op: String
    var params: AppJSON
    /// `user` inside a gesture, else `script`.
    var origin: String
}

/// A refusal or failure of a Mac-side app op. Codes follow the app ABI
/// (`operation.unsupported`, `invalid_params`, an owner's own code).
nonisolated struct AppHostCapabilityError: Error, Sendable {
    var code: String
    var message: String
    var retryable = false
    var details: AppJSON?

    static func unsupported(_ op: String) -> AppHostCapabilityError {
        AppHostCapabilityError(code: "operation.unsupported", message: "\(op) is not available in this build", details: ["op": .string(op)])
    }
}
