public import Foundation

/// A strongly typed UUID carried by the terminal-backend protocol.
public protocol BackendIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
    /// The UUID encoded on the wire.
    var rawValue: UUID { get }

    /// Creates a typed backend identifier.
    ///
    /// - Parameter rawValue: The UUID to wrap.
    init(rawValue: UUID)
}

public extension BackendIdentifier {
    /// Decodes a typed identifier from its single UUID value.
    ///
    /// - Parameter decoder: The decoder containing the UUID value.
    /// - Throws: Any error raised while decoding the UUID.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UUID.self))
    }

    /// Encodes the identifier as its single UUID value.
    ///
    /// - Parameter encoder: The encoder that receives the UUID value.
    /// - Throws: Any error raised while encoding the UUID.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The lowercase UUID string used by protocol requests.
    var description: String { rawValue.uuidString.lowercased() }
}
