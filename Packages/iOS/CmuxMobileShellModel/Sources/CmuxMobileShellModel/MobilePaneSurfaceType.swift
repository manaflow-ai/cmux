/// The content kind displayed by a pane surface.
public enum MobilePaneSurfaceType: Sendable, Equatable {
    /// A streamable terminal surface.
    case terminal
    /// A browser surface.
    case browser
    /// A rendered Markdown surface.
    case markdown
    /// A file preview surface.
    case filepreview
    /// A right-sidebar tool surface.
    case rightSidebarTool
    /// A custom-sidebar surface.
    case customSidebar
    /// An agent-session surface.
    case agentSession
    /// A project surface.
    case project
    /// An extension browser surface.
    case extensionBrowser
    /// A workspace todo surface.
    case workspaceTodo
    /// A cloud VM loading surface.
    case cloudVMLoading
    /// A surface kind introduced by a newer Mac version.
    case other(String)

    /// Whether this surface type can be streamed through the mobile terminal lane.
    public var isTerminal: Bool {
        if case .terminal = self {
            return true
        }
        return false
    }
}
