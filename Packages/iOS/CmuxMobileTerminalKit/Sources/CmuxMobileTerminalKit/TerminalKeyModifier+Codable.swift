import Foundation

/// `Codable` conformance for ``TerminalKeyModifier`` so custom toolbar actions
/// that encode a key combination can persist their modifier set.
///
/// Encoded as the raw bit set (a single `Int`), matching the option-set's
/// `rawValue`, so the JSON form stays compact and stable.
extension TerminalKeyModifier: Codable {
    /// Decodes a modifier set from its raw bit set.
    /// - Parameter decoder: The decoder reading a single `Int` value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    /// Encodes the modifier set as its raw bit set.
    /// - Parameter encoder: The encoder receiving a single `Int` value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
