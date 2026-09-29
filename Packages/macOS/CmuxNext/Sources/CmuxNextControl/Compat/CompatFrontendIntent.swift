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
    /// Runs a browser operation on the page of a browser tab, creating the
    /// page if the tab was never shown.
    case browser(tabID: String, url: String?, operation: CompatBrowserOperation)
}

public enum CompatBrowserOperation: Sendable, Hashable {
    case navigate(String)
    case back, forward, reload
    /// Result: `{"url": …, "title": …}`.
    case state
    /// Result: `{"value": <JSON>}`.
    case evaluate(String)
}
