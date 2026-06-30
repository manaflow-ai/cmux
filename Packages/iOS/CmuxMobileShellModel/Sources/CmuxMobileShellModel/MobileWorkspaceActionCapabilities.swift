/// Workspace actions supported by the Mac that owns a workspace row.
public struct MobileWorkspaceActionCapabilities: Equatable, Sendable {
    /// Whether rename and pin/unpin workspace actions are supported.
    public var supportsWorkspaceActions: Bool
    /// Whether mark read/unread workspace actions are supported.
    public var supportsReadStateActions: Bool
    /// Whether workspace close requests are supported.
    public var supportsCloseActions: Bool
    /// Whether terminal close requests are supported.
    public var supportsTerminalCloseActions: Bool

    /// No workspace actions are supported.
    public static let none = MobileWorkspaceActionCapabilities()

    /// Create a workspace action capability snapshot.
    public init(
        supportsWorkspaceActions: Bool = false,
        supportsReadStateActions: Bool = false,
        supportsCloseActions: Bool = false,
        supportsTerminalCloseActions: Bool = false
    ) {
        self.supportsWorkspaceActions = supportsWorkspaceActions
        self.supportsReadStateActions = supportsReadStateActions
        self.supportsCloseActions = supportsCloseActions
        self.supportsTerminalCloseActions = supportsTerminalCloseActions
    }
}
