public import CmuxMobileShellModel

/// Immutable tab data consumed by Pane Rack rows.
public struct PaneRackTabSnapshot: Identifiable, Equatable, Sendable {
    /// Stable terminal surface identifier.
    public var id: MobileTerminalPreview.ID
    /// User-facing terminal title.
    public var title: String
    /// Whether the terminal is ready to mount.
    public var isReady: Bool
    /// Whether the terminal holds Mac focus.
    public var isMacFocused: Bool
    /// Joined agent activity for the terminal.
    public var agentState: PaneRackAgentState

    /// Creates an immutable Pane Rack tab snapshot.
    /// - Parameters:
    ///   - id: Stable terminal surface identifier.
    ///   - title: User-facing terminal title.
    ///   - isReady: Whether the terminal is ready to mount.
    ///   - isMacFocused: Whether the terminal holds Mac focus.
    ///   - agentState: Joined agent activity for the terminal.
    public init(
        id: MobileTerminalPreview.ID,
        title: String,
        isReady: Bool,
        isMacFocused: Bool,
        agentState: PaneRackAgentState
    ) {
        self.id = id
        self.title = title
        self.isReady = isReady
        self.isMacFocused = isMacFocused
        self.agentState = agentState
    }
}
