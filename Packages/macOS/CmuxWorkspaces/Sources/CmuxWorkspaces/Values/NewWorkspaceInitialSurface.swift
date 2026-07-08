/// The kind of surface a brand-new workspace boots with.
///
/// `.terminal` is the historical default. `.browser` backs the
/// "New Browser Workspace" action: identical placement and naming
/// semantics, but the initial surface is a browser pane in its
/// default new-tab state instead of a terminal.
public enum NewWorkspaceInitialSurface: Sendable {
    /// The historical default: a terminal surface.
    case terminal
    /// A browser pane in its default new-tab state.
    case browser
    /// A transient Cloud VM loading surface. It is swapped for a terminal once attach is ready.
    case cloudVMLoading
}
