import CryptoKit
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
    public func send(operation: String, params: [String: JSONValue], idempotencyKey: String?,
                     origin: JSONValue? = nil) async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: idempotencyKey, origin: origin)
        }, as: JSONValue.self)
    }

    /// The daemon capability that accepts the `origin` envelope field and
    /// `origin.confirmation.issue` (page calls narrowed to `page`, raised to `user` only with a
    /// native-sheet confirmation token).
    public static let originClaimCapability = "origin-claim-v1"

    /// SHA-256 (hex) of `params` as sent (defaults filled in), canonical JSON: sorted keys, no
    /// whitespace, UTF-8. A confirmation token is bound to it.
    public static func paramsDigest(_ params: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ResourceRequestEnvelope.wireParams(params))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
