import Foundation

extension DaemonConnection {
    /// Sends one `cmux.protocol/2` resource operation that the compiled action catalog names (a
    /// catalog request row, an `op:` suggestion list: `CatalogRequestHandlers`), and returns its
    /// `result` as JSON. The caller passes only catalog operation names, never user config. A
    /// `mutation` carries a fresh idempotency key, as the CLI's does; a read carries none.
    public func catalogOperation(_ operation: String, params: [String: JSONValue], mutation: Bool) async throws -> JSONValue {
        let key = mutation ? "cmux-next-catalog-" + UUID().uuidString.lowercased() : nil
        return try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: key)
        }, as: JSONValue.self)
    }
}
