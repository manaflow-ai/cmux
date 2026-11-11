#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextSettings
import CmuxNextSidebar

/// DEBUG ONLY: `debug.sidebar_priority_loading {window?, state?}` draws the active window's real
/// Priority view with no rows in one of its three states, for captures of ui-state-fixes M6:
/// `loading` (default; no chat list read: "Loading agent chats…"), `failed` (none read within
/// `SidebarPriorityFeed.loadDeadline`: "Couldn’t load agent chats.") or `empty` (a list read with
/// no chat: "No agent chats right now"). `retry` sends the panel's Try Again action
/// (`.retryLoad`) to the window's real Priority feed, as the button does. The Priority feed's next
/// change draws its own panel again. Compiled out of Release.
@MainActor
enum DebugSidebarPriorityLoading {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let controller = params["window"]?.stringValue.flatMap { services.windows.controller(for: $0) } ?? services.windows.active
        guard let sidebar = controller?.sidebar.container.sidebarView else {
            return .object(["error": .string("no window sidebar")])
        }
        let state = params["state"]?.stringValue ?? "loading"
        if state == "retry" {
            // Try Again: the action the panel's Try Again button sends, to the window's real Priority feed.
            guard let action = sidebar.onPriorityAction else { return .object(["error": .string("no Priority feed on this sidebar")]) }
            action(.retryLoad)
            return .object(["ok": .bool(true), "state": .string(state)])
        }
        let panel: SidebarPriorityPanel
        switch state {
        case "loading": panel = SidebarPriorityPanel(entries: [], shown: true, loaded: false)
        case "failed": panel = SidebarPriorityPanel(entries: [], shown: true, loaded: false, loadFailed: true)
        case "empty": panel = SidebarPriorityPanel(entries: [], shown: true, loaded: true)
        default: return .object(["error": .string("state must be loading, failed, empty or retry")])
        }
        sidebar.showPriority(panel)
        return .object(["ok": .bool(true), "state": .string(state)])
    }
}
#endif
