/// Runtime state exposed for one semantic element.
public struct SimulatorUIAutomationElementState: Codable, Equatable, Sendable {
    /// Whether the element accepts interaction.
    public let isEnabled: Bool
    /// Whether the native accessibility bridge reports keyboard focus.
    public let isFocused: Bool?
    /// Whether the native accessibility bridge reports selection.
    public let isSelected: Bool?
    /// Whether the element has a usable frame intersecting the viewport.
    public let isVisible: Bool

    /// Creates normalized state for one accessibility element.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the element accepts interaction.
    ///   - isFocused: Optional focus state from the native bridge.
    ///   - isSelected: Optional selection state from the native bridge.
    ///   - isVisible: Whether the element intersects the foreground viewport.
    public init(
        isEnabled: Bool,
        isFocused: Bool?,
        isSelected: Bool?,
        isVisible: Bool
    ) {
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.isVisible = isVisible
    }
}
