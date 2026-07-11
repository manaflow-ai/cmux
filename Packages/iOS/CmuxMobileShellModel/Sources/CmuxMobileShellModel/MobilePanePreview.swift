/// A stable, spatially ordered pane snapshot inside a mobile workspace.
public struct MobilePanePreview: Identifiable, Equatable, Sendable {
    /// A stable, string-backed pane identifier.
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        /// The underlying pane identifier string.
        public var rawValue: String

        /// Creates an identifier from its raw string value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Creates an identifier from a string literal.
        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    /// The pane's stable identifier.
    public var id: ID
    /// The zero-based spatial position, ordered left-to-right then top-to-bottom.
    public var spatialIndex: Int
    /// Whether this is the workspace's focused pane.
    public var isFocused: Bool
    /// Stable terminal identities in the pane's tab order.
    public var terminalIDs: [MobileTerminalPreview.ID]

    /// Creates a pane preview.
    public init(
        id: ID,
        spatialIndex: Int,
        isFocused: Bool = false,
        terminalIDs: [MobileTerminalPreview.ID]
    ) {
        self.id = id
        self.spatialIndex = spatialIndex
        self.isFocused = isFocused
        self.terminalIDs = terminalIDs
    }
}
