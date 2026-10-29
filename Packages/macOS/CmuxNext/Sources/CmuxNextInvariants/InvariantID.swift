/// The id of one declared invariant (plans/cmux-next/invariants-DESIGN.md section 2.2): `W10`, `LG1`, or
/// `INV-COST@W10` for a rule that costs too much. The app and the daemon share the namespace. It compiles in every
/// build, because a Release probe call names it (and does nothing with it).
public struct InvariantID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible {
    public let rawValue: String

    @inlinable public init(rawValue: String) { self.rawValue = rawValue }

    @inlinable public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
