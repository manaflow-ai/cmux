#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextSettings
import CmuxNextSidebar

/// DEBUG ONLY: `debug.sidebar_priority_loading {window?, state?}` draws the active window's real
/// Priority view with no rows in one of its three states, for captures of ui-state-fixes M6:
/// `loading` (default; no chat list read: "Loading agent chats…"), `failed` (none read within
/// `SidebarPriorityFeed.loadDeadline`: "Couldn’t load agent chats.") or `empty` (a list read with
/// no chat: "No agent chats right now"). The Priority feed's next change draws its own panel
/// again. Compiled out of Release.
@MainActor
enum DebugSidebarPriorityLoading {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let controller = params["window"]?.stringValue.flatMap { services.windows.controller(for: $0) } ?? services.windows.active
        guard let sidebar = controller?.sidebar.container.sidebarView else {
            return .object(["error": .string("no window sidebar")])
        }
        let state = params["state"]?.stringValue ?? "loading"
        let panel: SidebarPriorityPanel
        switch state {
        case "loading": panel = SidebarPriorityPanel(entries: [], shown: true, loaded: false)
        case "failed": panel = SidebarPriorityPanel(entries: [], shown: true, loaded: false, loadFailed: true)
        case "empty": panel = SidebarPriorityPanel(entries: [], shown: true, loaded: true)
        default: return .object(["error": .string("state must be loading, failed or empty")])
        }
        sidebar.showPriority(panel)
        return .object(["ok": .bool(true), "state": .string(state)])
    }
}
#endif
