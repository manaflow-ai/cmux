#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextAgentLanes
import CmuxNextSettings
import CmuxNextSidebar

/// DEBUG ONLY: `debug.sidebar_priority_hold {action, window?}` drives every window's real Priority
/// feed through its load states, for captures of ui-state-fixes M6 (``SidebarPriorityDebugHold``):
/// - `hold`: the chat list read is held, as if no list had come. The feed shows "Loading agent
///   chats…"; its own deadline (`SidebarPriorityFeed.loadDeadline`, 10 s) ends that in "Couldn't
///   load agent chats." with Try Again.
/// - `retry`: the action the panel's Try Again button sends (`.retryLoad`), to the window's real
///   feed: its product retry runs (the chat lists' watches connect again) and it shows loading again
///   under a fresh deadline.
/// - `release`: the hold ends; the feed reads its real chat lists again (the chats, or "No agent
///   chats right now" once a store delivered an empty page).
/// - `read` (default): changes nothing.
/// Every answer reads back `held`, what the feed last showed (`shown`: loading, failed, empty, list)
/// and whether a real chat list was read (`listed`). Compiled out of Release.
@MainActor
enum DebugSidebarPriorityHold {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let hold = SidebarPriorityDebugHold.shared
        let action = params["action"]?.stringValue ?? "read"
        switch action {
        case "hold": hold.held = true
        case "release": hold.held = false
        case "retry":
            let controller = params["window"]?.stringValue.flatMap { services.windows.controller(for: $0) } ?? services.windows.active
            guard let perform = controller?.sidebar.container.sidebarView.onPriorityAction else {
                return .object(["error": .string("no Priority feed on this window's sidebar")])
            }
            perform(.retryLoad)
        case "read": break
        default: return .object(["error": .string("action must be hold, retry, release or read")])
        }
        return .object([
            "action": .string(action),
            "held": .bool(hold.held),
            "shown": hold.shown.map(JSONValue.string) ?? .null,
            "listed": .bool(AgentPriorityChats.app.listed()),
        ])
    }
}
#endif
