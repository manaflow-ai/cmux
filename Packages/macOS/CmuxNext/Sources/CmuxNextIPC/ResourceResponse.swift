public import Foundation

/// A `cmux.protocol/2` response line: `ok: true` with the operation's `result`, or `ok: false`
/// with the structured `error`. Generated requests name theirs `Request.Response`
/// (`ResourceResponse<Request.Result, V2ResourceError>`); the line is decoded once.
public enum ResourceResponse<Value: Decodable & Sendable, Failure: Error & Decodable>: Decodable, Sendable {
    case success(Value)
    case failure(Failure)

    enum CodingKeys: String, CodingKey {
        case ok, result, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .ok) {
            self = .success(try container.decode(Value.self, forKey: .result))
        } else {
            self = .failure(try container.decode(Failure.self, forKey: .error))
        }
    }

    /// Decodes `line`, the response to an `operation` request.
    public init(line: Data, operation: String, using decoder: JSONDecoder) throws(ResourceWireError) {
        do {
            self = try decoder.decode(Self.self, from: line)
        } catch {
            throw .undecodable(operation: operation, reason: "\(error)")
        }
    }

    /// The result, or the structured error thrown.
    public func get() throws(Failure) -> Value {
        switch self {
        case .success(let value): return value
        case .failure(let failure): throw failure
        }
    }
}

/// A `stream_open` operation: its stream's items and its end (resource-api-v2.md, streams).
/// Streams take no idempotency key.
public protocol ResourceStreamRequest: ResourceUnkeyedRequest {
    associatedtype StreamItem: Decodable & Sendable
    associatedtype StreamEnd: Decodable & Sendable
}
