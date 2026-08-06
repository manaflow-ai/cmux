/// One stable finite-choice value and its localized label.
public struct CommandPaletteChoice: Sendable, Equatable, Identifiable {
    /// Stable machine-readable value supplied to the command handler.
    public let value: String
    /// Localized label displayed in the palette.
    public let title: String

    /// Stable identity derived from ``value``.
    public var id: String { value }

    /// Creates one selectable value.
    /// - Parameters:
    ///   - value: Stable machine-readable value supplied to the handler.
    ///   - title: Localized label displayed in the palette.
    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}
