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

/// Handles every op of the families it names (the op prefix before the
/// first dot, for example `coderouter`).
nonisolated protocol AppHostCapabilityHandler: Sendable {
    var families: Set<String> { get }
    func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON
}

/// The Mac-side handlers by family; the one place a caller (prototype
/// engine now, provider channel later) looks an op up.
nonisolated struct AppHostCapabilities: Sendable {
    private let handlers: [String: any AppHostCapabilityHandler]

    init(_ handlers: [any AppHostCapabilityHandler]) {
        var byFamily: [String: any AppHostCapabilityHandler] = [:]
        for handler in handlers {
            for family in handler.families { byFamily[family] = handler }
        }
        self.handlers = byFamily
    }

    static func family(of op: String) -> String { String(op.prefix { $0 != "." }) }

    func handles(_ op: String) -> Bool { handlers[Self.family(of: op)] != nil }

    func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard let handler = handlers[Self.family(of: request.op)] else { throw .unsupported(request.op) }
        return try await handler.handle(request)
    }
}
