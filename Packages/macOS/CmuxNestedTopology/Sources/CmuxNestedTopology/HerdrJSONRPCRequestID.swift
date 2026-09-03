import Foundation

/// Typed correlation identifier for one Herdr JSON-RPC request line.
public struct HerdrJSONRPCRequestID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Opaque request token written as the wire `id` string.
    public let rawValue: String

    /// Creates a request ID from an opaque token.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a fresh random request ID suitable for Herdr correlation.
    public static func random(prefix: String = "cmux") -> HerdrJSONRPCRequestID {
        HerdrJSONRPCRequestID(rawValue: "\(prefix)-\(UUID().uuidString.lowercased())")
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
