internal import Foundation

extension ControlCommandCoordinator {
    /// `workspace_loading <key> <on|off> [--tab=<id>]` toggles a workspace-scoped
    /// manual loading state and replies `before=ON;after=OFF`.
    nonisolated func sidebarWorkspaceLoading(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        let usage = "workspace_loading <key> <on|off> [--tab=<id>]"
        guard parsed.positional.count >= 2 else {
            return "ERROR: Usage: \(usage)"
        }
        let key = parsed.positional[0]
        guard key == "manual" || key.hasPrefix("manual:") else {
            return "ERROR: workspace_loading only accepts manual loader keys (manual or manual:<id>); use set_agent_lifecycle for agent keys"
        }
        if key != "manual" {
            let id = key.dropFirst("manual:".count)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(allowed.contains) else {
                return "ERROR: Invalid manual loader id; use 1-64 characters from letters, digits, '.', '_', '-'"
            }
        }
        let on: Bool
        switch parsed.positional[1].lowercased() {
        case "on", "running", "start", "show":
            on = true
        case "off", "idle", "stop", "hide":
            on = false
        default:
            return "ERROR: Usage: \(usage)"
        }
        let tabArg = parsed.options["tab"]
        if let tabArg, tabArg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "ERROR: Invalid --tab; expected a workspace id, ref, or index"
        }
        let result = context?.controlSidebarOnMain {
            $0.controlSidebarSetWorkspaceLoading(
                tabArg: tabArg,
                key: key,
                on: on
            )
        }
        guard let result = result ?? nil else {
            return "ERROR: Workspace not found"
        }
        if let failureReason = result.failureReason {
            return "ERROR: \(failureReason)"
        }
        func label(_ value: Bool) -> String { value ? "ON" : "OFF" }
        return "before=\(label(result.before));after=\(label(result.after))"
    }
}
