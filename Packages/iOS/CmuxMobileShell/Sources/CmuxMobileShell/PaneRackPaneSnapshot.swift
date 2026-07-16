public import CmuxMobileShellModel

/// Immutable pane data consumed by Pane Rack strips and the staged header.
public struct PaneRackPaneSnapshot: Identifiable, Equatable, Sendable {
    /// Stable pane identifier, including the phone-synthesized old-Mac pane.
    public var id: String
    /// Pane geometry normalized to the workspace container.
    public var rect: MobilePaneNormalizedRect
    /// Whether the pane holds Mac focus.
    public var isMacFocused: Bool
    /// Phone-local effective selected terminal in this pane.
    public var selectedTabID: MobileTerminalPreview.ID?
    /// Terminal tabs in Mac tab order.
    public var tabs: [PaneRackTabSnapshot]

    /// Creates an immutable Pane Rack pane snapshot.
    /// - Parameters:
    ///   - id: Stable pane identifier.
    ///   - rect: Pane geometry normalized to the workspace container.
    ///   - isMacFocused: Whether the pane holds Mac focus.
    ///   - selectedTabID: Phone-local effective selected terminal.
    ///   - tabs: Terminal tabs in Mac tab order.
    public init(
        id: String,
        rect: MobilePaneNormalizedRect,
        isMacFocused: Bool,
        selectedTabID: MobileTerminalPreview.ID?,
        tabs: [PaneRackTabSnapshot]
    ) {
        self.id = id
        self.rect = rect
        self.isMacFocused = isMacFocused
        self.selectedTabID = selectedTabID
        self.tabs = tabs
    }
}
