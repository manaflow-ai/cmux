/// The kind of surface a brand-new workspace boots with.
///
/// `.terminal` is the historical default. `.browser` backs the
/// "New Browser Workspace" action: identical placement and naming
/// semantics, but the initial surface is a browser pane in its
/// default new-tab state instead of a terminal. `.agentSession` boots
/// directly into cmux's bundled agent-session webview.
public enum NewWorkspaceInitialSurface: Sendable {
    /// The historical default: a terminal surface.
    case terminal
    /// A browser pane in its default new-tab state.
    case browser
    /// A native agent-session surface backed by cmux's bundled webview app.
    case agentSession
    /// A transient Cloud VM loading surface. It is swapped for a terminal once attach is ready.
    case cloudVMLoading
}
