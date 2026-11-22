import Foundation

/// Stable id of a section (`sec_…`), minted by the client that adds it.
public nonisolated struct LayoutSectionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
    /// A new random id.
    public static func mint() -> LayoutSectionID { LayoutSectionID("sec_" + LayoutIDs.random()) }
}

/// Stable id of an item (`itm_…`); it survives moves between sections.
public nonisolated struct LayoutItemID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
    public static func mint() -> LayoutItemID { LayoutItemID("itm_" + LayoutIDs.random()) }
    /// A client-only item (`client.` prefix): drawn by this window, never in
    /// the layout document, so it cannot be dragged, edited or hidden.
    public var isTransient: Bool { rawValue.hasPrefix(Self.transientPrefix) }
    public static let transientPrefix = "client."
}

nonisolated enum LayoutIDs {
    /// 16 lowercase base32 characters (80 bits).
    static func random() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var generator = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet[Int(generator.next(upperBound: UInt32(alphabet.count)))] })
    }
}
