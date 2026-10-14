#if DEBUG
import CmuxNextSettings
import CmuxNextSidebar

/// DEBUG ONLY. `debug.sidebar_apply` {ops, title?}: sends sidebar document
/// ops through the app's document store (applied to the mirror, sent to the
/// daemon, one undo step titled `title`), as a menu edit does. A proof adds
/// what no app action adds yet (a link with its favicon) on the real client
/// path. Reply: {ok} or {ok: false, error}.
@MainActor
enum DebugSidebarApply {
    static func run(_ params: [String: JSONValue]) -> JSONValue {
        guard let store = SidebarDocStore.current, store.isActive else { return failure("the sidebar document is not active") }
        guard case .array(let list)? = params["ops"], let ops = list.map(\.foundationObject) as? [[String: Any]], !ops.isEmpty else {
            return failure("ops must be a non-empty list of op objects")
        }
        do {
            try store.sendChecked(ops: ops, title: params["title"]?.stringValue ?? "Sidebar Edit", undoable: true)
        } catch {
            return failure(error.message)
        }
        return .object(["ok": .bool(true)])
    }

    private static func failure(_ message: String) -> JSONValue {
        .object(["ok": .bool(false), "error": .string(message)])
    }
}
#endif
