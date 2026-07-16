/// A lightweight, `Sendable` snapshot of one pane and its ordered terminal tabs.
public struct MobilePanePreview: Identifiable, Equatable, Sendable {
    /// Stable pane identifier.
    public var id: String
    /// Terminal surface identifiers in Mac tab order.
    public var tabIDs: [String]
    /// The Mac-selected terminal tab, when one is reported.
    public var selectedTabID: String?
    /// Whether the pane currently holds focus on the Mac.
    public var isFocused: Bool
    /// Pane geometry normalized to the workspace container.
    public var rect: MobilePaneNormalizedRect

    /// Creates a pane preview.
    /// - Parameters:
    ///   - id: Stable pane identifier.
    ///   - tabIDs: Terminal surface identifiers in Mac tab order.
    ///   - selectedTabID: The Mac-selected terminal tab, when one is reported.
    ///   - isFocused: Whether the pane currently holds focus on the Mac.
    ///   - rect: Pane geometry normalized to the workspace container.
    public init(
        id: String,
        tabIDs: [String],
        selectedTabID: String? = nil,
        isFocused: Bool = false,
        rect: MobilePaneNormalizedRect
    ) {
        self.id = id
        self.tabIDs = tabIDs
        self.selectedTabID = selectedTabID
        self.isFocused = isFocused
        self.rect = rect
    }
}
