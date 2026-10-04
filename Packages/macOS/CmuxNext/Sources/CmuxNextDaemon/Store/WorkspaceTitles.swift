public import Observation

/// Titles a client gives workspaces the store names by default
/// (app-screens.md 2). One per store; every `WorkspaceModel.displayName`
/// reads it, so the sidebar, the window title, the palette and every other
/// reader show the same title.
@Observable @MainActor
public final class WorkspaceTitles {
    /// The workspace kind of an app's companion workspace, which holds the
    /// tabs sent to the app's workspace (`app-screens-v1`).
    public static let appTabsKind = "app_tabs"

    /// The localized "<App name> Tabs" for an app id, or nil while the app
    /// is unknown (the stored name shows). Set by the app.
    public var appTabs: (@MainActor (String) -> String?)?

    public init() {}
}
