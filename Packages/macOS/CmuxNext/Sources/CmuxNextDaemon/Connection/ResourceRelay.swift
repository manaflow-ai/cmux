import Foundation

/// One `cmux.protocol/2` operation named at runtime, for relays that forward a caller's typed
/// op unchanged (the React pages' bridge: `cmux.history.entries.list` -> `history.entries.list`;
/// plans/cmux-next/react-pages.md 1.1). The daemon validates params against its catalog; the
/// relay never interprets them. Its own type, not a `DaemonConnection` member (that type's line
/// budget is frozen).
public struct ResourceRelayClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// Sends `operation` with `params` and returns its raw `result`. Mutations need
    /// `idempotencyKey`; refusals arrive as `DaemonError.command` with the daemon's code.
    public func send(operation: String, params: [String: JSONValue], idempotencyKey: String?) async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: idempotencyKey)
        }, as: JSONValue.self)
    }
}
