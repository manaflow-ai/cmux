import Foundation

/// Serves the Agent Memory app's `memory.search` from the agent memory index.
///
/// The index answers only while `agents.memory.enabled` is on and this build
/// has the index tool; otherwise the op stays `operation.unsupported`, and the
/// app searches the file names and texts it already read. The app's `roots`
/// are accepted and not used: the index is one root, `agent-memory`, and it
/// never reads a path the app names. Only the first-party Agent Memory app
/// (`cmux/memory`) reads the index: it also holds saved notes, the
/// `agents.memory.sources` folders and the owner machine's memory, more than
/// the `memory:read` consent names, so another app holding that scope gets
/// `operation.unsupported`. Other `memory.*` ops stay unsupported.
public nonisolated struct AgentMemorySearchHandler: AppHostCapabilityHandler {
    private let enabled: @MainActor @Sendable () -> Bool
    private let index: (any AgentMemoryIndex)?

    /// Hits when the app sends no limit (the index tool's own default).
    static let defaultLimit = 20
    /// The most hits one search returns (the index tool's own cap).
    static let maximumLimit = 200
    /// The longest query, in UTF-8 bytes.
    static let maximumQueryBytes = 1024
    /// The one app that reads the index.
    static let memoryApp = "cmux/memory"

    /// The capability family supplied on the verified-app provider channel.
    public var families: Set<String> { ["memory"] }

    /// Creates the handler from the app's settings and its bundled index tool.
    /// - Parameters:
    ///   - enabled: Whether `agents.memory.enabled` is on now; read at each call.
    ///   - index: The index, or nil when this build has no index tool.
    public init(enabled: @escaping @MainActor @Sendable () -> Bool, index: (any AgentMemoryIndex)?) {
        self.enabled = enabled
        self.index = index
    }

    /// Searches the index and answers `{hits: [{root, path, line, text, id, date}]}`.
    /// - Parameter request: The supervisor-admitted `memory.search` call.
    /// - Returns: The hits in the app's shape.
    /// - Throws: `operation.unsupported` while memory is off or for other ops,
    ///   `validation.invalid` for malformed params, or the index's failure.
    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.op == "memory.search", request.app == Self.memoryApp else { throw .unsupported(request.op) }
        guard await enabled(), let index else { throw .unsupported(request.op) }
        let (query, limit) = try Self.parse(request.params)
        let hits = try await index.search(query: query, limit: limit)
        return ["hits": .array(hits.map(\.appHit))]
    }

    /// `{roots: [string], query: string, limit?: integer >= 1}`: the trimmed query and the capped limit.
    private static func parse(_ params: AppJSON) throws(AppHostCapabilityError) -> (String, Int) {
        guard let fields = params.objectValue,
              fields.keys.allSatisfy({ ["roots", "query", "limit"].contains($0) }),
              let roots = fields["roots"]?.arrayValue, roots.allSatisfy({ $0.stringValue != nil }),
              let query = fields["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty, query.utf8.count <= maximumQueryBytes else { throw invalid() }
        guard let field = fields["limit"] else { return (query, defaultLimit) }
        guard let number = field.numberValue, number.rounded() == number, number >= 1 else { throw invalid() }
        return (query, number >= Double(maximumLimit) ? maximumLimit : Int(number))
    }

    private static func invalid() -> AppHostCapabilityError {
        AppHostCapabilityError(code: "validation.invalid",
                               message: String(localized: "apps.memory.validation.invalid", defaultValue: "Expected roots, a query and an optional limit", bundle: .module))
    }
}
