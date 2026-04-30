import Foundation

public struct NoSocketParams: Codable, Equatable, Sendable {
    public init() {}
}

public struct SocketCommand<Params: Codable & Sendable>: Codable, Sendable {
    public let id: String?
    public let method: SocketMethod
    public let params: Params?

    public init(id: String? = nil, method: SocketMethod, params: Params? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        method = try container.decode(SocketMethod.self, forKey: .method)
        params = try container.decodeIfPresent(Params.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
    }
}

extension SocketCommand: Equatable where Params: Equatable {}
