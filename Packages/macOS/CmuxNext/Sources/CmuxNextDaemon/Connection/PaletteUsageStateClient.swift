import Foundation

/// The user's palette usage history as protocol-v2 state operations
/// (`palette-usage-v1`, plans/cmux-next/palette-ranking.md 5.2-5.3). The
/// daemon is the history's one writer and stamps each use with its clock;
/// values stay JSON here and the palette decodes them.
public struct PaletteUsageStateClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// The whole history (`PaletteUsageSnapshot`).
    public func get() async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "palette_usage.get", params: [:], idempotencyKey: nil)
        }, as: JSONValue.self)
    }

    /// One run of row `key` for `query`; returns `PaletteUsageRecordResult`
    /// (`{revision}` only: read the history with `get`).
    public func record(key: String, query: String, idempotencyKey: String) async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "palette_usage.record",
                                    params: ["key": .string(key), "query": .string(query)], idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self).value
    }

    /// Merges a former history from `source` once; returns
    /// `PaletteUsageImportResult` (`{revision, imported}`).
    public func importHistory(source: String, entries: [JSONValue], idempotencyKey: String) async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "palette_usage.import",
                                    params: ["source": .string(source), "entries": .array(entries)], idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self).value
    }
}
