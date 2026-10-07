import CmuxNextApps
import Foundation

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
