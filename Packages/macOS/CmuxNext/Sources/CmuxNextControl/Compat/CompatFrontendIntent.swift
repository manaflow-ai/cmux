/// App-owned operations the CLI requests. Each targets model ids.
public enum CompatFrontendIntent: Sendable, Hashable {
    /// Show `workspaceID` in the window (default: active; opens one if none).
    case showWorkspace(workspaceID: String, windowID: String?)
    /// Show the pane's workspace and focus the pane.
    case focusPane(paneID: String, workspaceID: String, windowID: String?)
    /// Show, focus, and select the tab.
    case selectTab(tabID: String, paneID: String, workspaceID: String, windowID: String?)
    /// Opens a window showing `workspaceID` (or the active workspace). Result: `{"window_id": id}`.
    case newWindow(workspaceID: String?)
    case focusWindow(windowID: String)
    case closeWindow(windowID: String)
    /// A notification create is about to go to the daemon (its event may
    /// arrive before the reply); `noteNotification` follows.
    case expectNotification
    /// Tags daemon notification `id` with where it came from (`cli`,
    /// `terminal`, `agent`) for per-source notification settings; nil when
    /// the create failed.
    case noteNotification(id: UInt64?, source: String)
    /// Throws when a tab of workspace `from` may not move into workspace
    /// `to` (between an incognito window and a normal one).
    case checkTabMove(fromWorkspaceID: String, toWorkspaceID: String)
}

public enum CompatBrowserOperation: Sendable, Hashable {
    case navigate(String)
    case back, forward, reload
    /// Result: `{"url": …, "title": …}`.
    case state
    /// Result: `{"value": <JSON>}`.
    case evaluate(String)
}
