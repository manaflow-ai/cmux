public import Foundation

/// One `cmux.protocol/2` request line (cmux-tui/spec/resource-api-v2.md) built from a generated
/// request: the envelope builder that replaces hand-built `ResourceRequestEnvelope`s
/// (p05-ipc task 024). A mutation takes an idempotency key and a read cannot, by type.
///
/// The bytes equal the hand-built envelope's: sorted keys, unescaped slashes, the numeric id as a
/// decimal string (both envelopes share one waiter table), and `machine`/`session` selectors
/// `current` unless the caller names one.
public struct ResourceRequestLine<Request: ResourceOperationRequest>: Encodable, Sendable {
    public let id: UInt64
    public let request: Request
    public let idempotencyKey: ResourceIdempotencyKey?
    /// The caller's origin claim (`{claim: "page"}` or `{claim: "user", confirmation}`), sent only
    /// to a daemon with `origin-claim-v1`; nil keeps the connection's derived origin.
    public var origin: ResourceJSON?
    /// A launch credential the app minted (`credential.mint`): the request acts as its holder.
    /// Never logged.
    public var credential: String?

    enum CodingKeys: String, CodingKey {
        case type, id, operation, params, origin, credential
        case proto = "protocol"
        case idempotencyKey = "idempotency_key"
    }

    public init(id: UInt64, request: Request, origin: ResourceJSON? = nil, credential: String? = nil)
        where Request: ResourceUnkeyedRequest {
        self.id = id
        self.request = request
        self.idempotencyKey = nil
        self.origin = origin
        self.credential = credential
    }

    public init(id: UInt64, request: Request, idempotencyKey: ResourceIdempotencyKey, origin: ResourceJSON? = nil,
                credential: String? = nil) where Request: ResourceMutationRequest {
        self.id = id
        self.request = request
        self.idempotencyKey = idempotencyKey
        self.origin = origin
        self.credential = credential
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("cmux.protocol/2", forKey: .proto)
        try container.encode("request", forKey: .type)
        try container.encode(String(id), forKey: .id)
        try container.encode(Request.resourceOperation, forKey: .operation)
        try container.encode(request, forKey: .params)
        try container.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(credential, forKey: .credential)
    }

    /// The line's bytes, without the trailing newline the transport adds.
    public func line() throws(ResourceWireError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw .unencodable(operation: Request.resourceOperation, reason: "\(error)")
        }
    }
}

/// A mutation's idempotency key: 1 to 128 UTF-8 bytes, at least one scalar outside Unicode
/// `White_Space`, no `Cc` control scalar (resource-api-v2.md). A key the daemon would refuse is
/// refused here, before a line is built.
public struct ResourceIdempotencyKey: Hashable, Sendable, Encodable {
    public let rawValue: String

    public init(_ text: String) throws(ResourceWireError) {
        let scalars = text.unicodeScalars
        guard (1...128).contains(text.utf8.count),
              scalars.contains(where: { !$0.properties.isWhitespace }),
              !scalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw .invalidIdempotencyKey(text)
        }
        rawValue = text
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Why a resource line could not be built or read.
public enum ResourceWireError: Error, Equatable, Sendable {
    case invalidIdempotencyKey(String)
    case unencodable(operation: String, reason: String)
    /// A response line that is not a resource response of the expected result.
    case undecodable(operation: String, reason: String)
}
