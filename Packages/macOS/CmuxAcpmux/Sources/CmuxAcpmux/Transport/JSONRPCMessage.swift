import Foundation

/// One decoded inbound JSON-RPC 2.0 message.
public enum JSONRPCInbound: Sendable, Equatable {
    /// A response to a request this client sent.
    case response(id: Int, result: Result<JSONValue, JSONRPCError>)
    /// A notification (no `id`).
    case notification(method: String, params: JSONValue)
    /// A request from the daemon to the client. acpmux does not send these today.
    case request(id: JSONValue, method: String, params: JSONValue)

    /// Decodes one framed line.
    /// - Throws: `DecodingError` when the line is not a JSON-RPC object.
    public static func decode(_ line: Data) throws -> JSONRPCInbound {
        let envelope = try JSONDecoder().decode(Envelope.self, from: line)
        if let method = envelope.method {
            if let id = envelope.id, id != .null {
                return .request(id: id, method: method, params: envelope.params ?? .null)
            }
            return .notification(method: method, params: envelope.params ?? .null)
        }
        guard let id = envelope.id?.intValue else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "JSON-RPC response without integer id")
            )
        }
        if let error = envelope.error {
            return .response(id: id, result: .failure(error))
        }
        return .response(id: id, result: .success(envelope.result ?? .null))
    }

    private struct Envelope: Decodable {
        var id: JSONValue?
        var method: String?
        var params: JSONValue?
        var result: JSONValue?
        var error: JSONRPCError?
    }
}

/// A JSON-RPC error object.
public struct JSONRPCError: Error, Sendable, Equatable, Codable {
    /// The numeric error code.
    public var code: Int
    /// The human-readable message.
    public var message: String
    /// Optional structured data.
    public var data: JSONValue?

    /// Creates an error value.
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// An outbound JSON-RPC 2.0 request.
struct JSONRPCOutboundRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

/// An outbound JSON-RPC 2.0 notification.
struct JSONRPCOutboundNotification<Params: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}
