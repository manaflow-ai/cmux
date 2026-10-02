import Foundation

/// The catalog's surface declarations as JSON, checked in at
/// `plans/cmux-next/action-surfaces.json` so the Rust CLI and MCP parity
/// tests read the same list the app serves in `action.list` without a
/// running app. `ActionSurfaceParityTests.exportIsFresh` keeps it current.
public nonisolated enum ActionSurfaceExport {
    /// One action's wire form (also `action.list`'s `surfaces` member).
    public static func object(_ descriptor: ActionDescriptor) -> [String: Any] {
        let plan = descriptor.surfacePlan
        let contexts = plan.contextMenus.map(\.context.rawValue)
        var unique: [String] = []
        for context in contexts where !unique.contains(context) { unique.append(context) }
        return [
            "id": descriptor.id.rawValue,
            "cli_name": descriptor.cliName,
            "palette": plan.palette.wireValue,
            "cli": plan.cli?.wireValue ?? "undeclared",
            "context_menu": plan.contextMenu?.wireValue ?? "undeclared",
            "context_menus": unique,
            "mcp": plan.mcp?.wireValue ?? "undeclared",
        ]
    }

    /// The whole catalog, keys sorted, one stable text.
    public static func json(_ descriptors: [ActionDescriptor]) -> String {
        let root: [String: Any] = ["version": 1, "actions": descriptors.map(object)]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text + "\n"
    }
}
