#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextSettings
import CmuxNextSidebar

/// DEBUG ONLY: `debug.sidebar_priority_loading {window?}` draws the active window's real Priority
/// view as it is before any chat list was read (``SidebarPriorityPanel/loaded`` false, no rows),
/// for captures of ui-state-fixes M6 ("Loading agent chats…"). The Priority feed's next change
/// draws its own panel again. Compiled out of Release.
@MainActor
enum DebugSidebarPriorityLoading {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let controller = params["window"]?.stringValue.flatMap { services.windows.controller(for: $0) } ?? services.windows.active
        guard let sidebar = controller?.sidebar.container.sidebarView else {
            return .object(["error": .string("no window sidebar")])
        }
        sidebar.showPriority(SidebarPriorityPanel(entries: [], shown: true, loaded: false))
        return .object(["ok": .bool(true)])
    }
}
#endif
