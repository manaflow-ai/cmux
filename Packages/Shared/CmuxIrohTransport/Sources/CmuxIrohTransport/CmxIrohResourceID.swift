/// A bounded opaque identifier for a terminal, artifact, or pairing invitation.
public struct CmxIrohResourceID: Equatable, Hashable, Sendable {
    /// The canonical ASCII identifier.
    public let value: String

    /// Creates a validated resource identifier.
    ///
    /// Identifiers contain 1 through 128 ASCII letters, digits, dots, colons,
    /// underscores, or hyphens. They never carry user-visible names.
    ///
    /// - Parameter value: The opaque identifier to validate.
    /// - Throws: ``CmxIrohResourceIDError/invalidValue`` for unsafe values.
    public init(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard (1 ... 128).contains(bytes.count), bytes.allSatisfy(Self.isAllowed) else {
            throw CmxIrohResourceIDError.invalidValue
        }
        self.value = value
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "."), UInt8(ascii: ":"), UInt8(ascii: "_"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }
}
