import Foundation

/// One `cmux.protocol/2` resource request (cmux-tui/spec/resource-api-v2.md)
/// on the same control socket as the raw protocol. The daemon routes a line
/// by its `protocol` field and answers with the request's string `id`; the
/// transport sends the numeric id as a decimal string so both envelopes
/// share one waiter table. Selectors are the flat `machine`/`session`/…
/// fields of `params`; this client always routes to the connected session
/// (`current`).
struct ResourceRequestEnvelope: Encodable {
    var id: UInt64
    var operation: String
    var params: [String: JSONValue]
    /// Required on mutations (1-128 UTF-8 bytes, no control characters).
    var idempotencyKey: String?
    /// The caller's origin claim (`{claim: "page"}` or `{claim: "user", confirmation}`), sent only
    /// to a daemon with `origin-claim-v1`; nil keeps the connection's derived origin.
    var origin: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type, id, operation, params, origin
        case proto = "protocol"
        case idempotencyKey = "idempotency_key"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("cmux.protocol/2", forKey: .proto)
        try c.encode("request", forKey: .type)
        try c.encode(String(id), forKey: .id)
        try c.encode(operation, forKey: .operation)
        var params = params
        params["machine"] = params["machine"] ?? .string("current")
        params["session"] = params["session"] ?? .string("current")
        try c.encode(params, forKey: .params)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        try c.encodeIfPresent(origin, forKey: .origin)
    }

    /// The `params` object exactly as it goes on the wire (the defaults filled in): what an
    /// origin confirmation token is bound to.
    static func wireParams(_ params: [String: JSONValue]) -> [String: JSONValue] {
        var params = params
        params["machine"] = params["machine"] ?? .string("current")
        params["session"] = params["session"] ?? .string("current")
        return params
    }

    func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decodes `result` of an `ok:true` resource response.
    static func decodeResult<R: Decodable>(_ type: R.Type, from line: Data) throws -> R {
        do {
            return try JSONDecoder().decode(ResourceResponseEnvelope<R>.self, from: line).result
        } catch {
            throw DaemonError.malformedResponse("\(R.self): \(error)")
        }
    }
}

struct ResourceResponseEnvelope<R: Decodable>: Decodable {
    var result: R
}
