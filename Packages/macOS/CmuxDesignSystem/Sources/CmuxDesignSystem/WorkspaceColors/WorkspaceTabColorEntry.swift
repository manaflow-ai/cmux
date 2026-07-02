/// A named workspace tab color token.
public struct WorkspaceTabColorEntry: Equatable, Identifiable, Sendable {
    /// The palette display name and stable identifier.
    public let name: String

    /// The color token as a normalized `#RRGGBB` hex string.
    public let hex: String

    /// Creates a workspace tab color token.
    ///
    /// - Parameters:
    ///   - name: The palette display name and stable identifier.
    ///   - hex: A six-digit hex color with or without a leading `#`.
    public init(name: String, hex: String) {
        self.name = name
        self.hex = WorkspaceColorHex(hex)?.rawValue ?? hex
    }

    /// The stable palette identifier.
    public var id: String { name }
}
