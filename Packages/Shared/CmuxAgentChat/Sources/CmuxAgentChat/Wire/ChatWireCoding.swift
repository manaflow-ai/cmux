import Foundation

/// The single source of truth for how chat wire payloads are JSON-encoded:
/// ISO 8601 dates on both ends of the connection.
///
/// Both the Mac host (producing) and mobile clients (consuming) go through
/// this type so the date strategy can never drift between the two.
public struct ChatWireCoding: Sendable {
    /// Creates a coder.
    public init() {}

    /// Encodes a wire value with the chat wire conventions.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: JSON data.
    /// - Throws: Any `JSONEncoder` error.
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// Decodes a wire value with the chat wire conventions.
    ///
    /// - Parameters:
    ///   - type: The value type to decode.
    ///   - data: JSON data.
    /// - Returns: The decoded value.
    /// - Throws: Any `JSONDecoder` error.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
