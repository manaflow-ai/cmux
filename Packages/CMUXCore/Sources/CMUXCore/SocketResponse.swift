import Foundation

public struct SocketErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let data: JSONValue?

    public init(code: String, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct SocketResponse<Result: Codable & Sendable>: Codable, Sendable {
    public let id: String?
    public let ok: Bool
    public let result: Result?
    public let error: SocketErrorPayload?

    public init(
        id: String? = nil,
        ok: Bool,
        result: Result? = nil,
        error: SocketErrorPayload? = nil
    ) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        ok = try container.decode(Bool.self, forKey: .ok)
        result = try container.decodeIfPresent(Result.self, forKey: .result)
        error = try container.decodeIfPresent(SocketErrorPayload.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }

        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ok
        case result
        case error
    }
}

extension SocketResponse: Equatable where Result: Equatable {}
