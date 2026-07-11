/// Workspace actions supported by the Mac that owns a workspace row.
public struct MobileWorkspaceActionCapabilities: Equatable, Sendable {
    /// Whether rename and pin/unpin workspace actions are supported.
    public var supportsWorkspaceActions: Bool
    /// Whether mark read/unread workspace actions are supported.
    public var supportsReadStateActions: Bool
    /// Whether workspace close requests are supported.
    public var supportsCloseActions: Bool
    /// Whether workspace move/reorder requests are supported.
    public var supportsMoveActions: Bool
    /// Whether workspace group mutation requests are supported.
    public var supportsGroupActions: Bool
    /// Whether exact terminal close requests are supported.
    public var supportsTerminalCloseActions: Bool
    /// Whether terminal creation can explicitly target the focused pane identity.
    public var supportsTerminalCreateInPane: Bool
    /// Whether strict in-pane terminal reorder requests are supported.
    public var supportsTerminalReorderActions: Bool

    /// No workspace actions are supported.
    public static let none = MobileWorkspaceActionCapabilities()

    /// Create a workspace action capability snapshot.
    public init(
        supportsWorkspaceActions: Bool = false,
        supportsReadStateActions: Bool = false,
        supportsCloseActions: Bool = false,
        supportsMoveActions: Bool = false,
        supportsGroupActions: Bool = false,
        supportsTerminalCloseActions: Bool = false,
        supportsTerminalCreateInPane: Bool = false,
        supportsTerminalReorderActions: Bool = false
    ) {
        self.supportsWorkspaceActions = supportsWorkspaceActions
        self.supportsReadStateActions = supportsReadStateActions
        self.supportsCloseActions = supportsCloseActions
        self.supportsMoveActions = supportsMoveActions
        self.supportsGroupActions = supportsGroupActions
        self.supportsTerminalCloseActions = supportsTerminalCloseActions
        self.supportsTerminalCreateInPane = supportsTerminalCreateInPane
        self.supportsTerminalReorderActions = supportsTerminalReorderActions
    }
}
