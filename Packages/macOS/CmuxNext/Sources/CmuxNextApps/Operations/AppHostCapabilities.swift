/// Routes app operations to the injected owner of their family.
///
/// The app composes its concrete handlers once and uses this same router
/// for the supervisor provider channel and its native pages. This router
/// does not grant scopes or authorize gestures; the caller admits the
/// request before dispatch and each handler enforces its operation contract.
public nonisolated struct AppHostCapabilities: Sendable {
    private let handlers: [String: any AppHostCapabilityHandler]

    /// Creates a router from the owners supplied by the app composition root.
    /// - Parameter handlers: Family owners. Within this router, the last owner
    ///   of a duplicate family replaces the previous one.
    public init(_ handlers: [any AppHostCapabilityHandler]) {
        var byFamily: [String: any AppHostCapabilityHandler] = [:]
        for handler in handlers {
            for family in handler.families { byFamily[family] = handler }
        }
        self.handlers = byFamily
    }

    /// The owned family of `op`: the longest one `op` starts with, up to a dot. A family can
    /// have a dot itself (`browser.page` owns `browser.page.eval`), as the daemon's `family_of`.
    private func family(of op: String) -> String? {
        handlers.keys.filter { op.hasPrefix($0 + ".") }.max { $0.count < $1.count }
    }

    /// The families with a handler (registered with `apps-provider-register`).
    public var families: Set<String> { Set(handlers.keys) }

    /// Whether a family owner exists; the owner still decides which ops it serves.
    /// - Parameter op: A full operation name such as `agent_cli.list` or `browser.page.eval`.
    /// - Returns: True when an owned family is a prefix of `op` up to a dot.
    public func handles(_ op: String) -> Bool { family(of: op) != nil }

    /// Dispatches an admitted request without altering its app, origin or params.
    /// - Parameter request: The request admitted by the caller's permission gate.
    /// - Returns: The owner's result, before the app ABI's `{value}` envelope.
    /// - Throws: `operation.unsupported` for an unowned family, or the owner's error.
    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard let family = family(of: request.op), let handler = handlers[family] else { throw .unsupported(request.op) }
        return try await handler.handle(request)
    }
}
