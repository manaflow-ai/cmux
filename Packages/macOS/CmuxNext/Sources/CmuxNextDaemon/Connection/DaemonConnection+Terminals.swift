import Foundation

/// Terminal lifetime beyond tabs (`terminal-reap-v1`): closing a tab only
/// detaches its terminal, and the daemon ends a terminal with no tab after
/// the reap grace period unless it is kept. A view restored within the grace
/// period (`terminal.project`) cancels the reap and keeps the scrollback.
extension DaemonConnection {
    /// Marks a terminal kept (outlives its last tab) or reapable.
    @discardableResult
    public func setTerminalKeep(_ target: SetTerminalKeepRequest.Target, keep: Bool) async throws -> SetTerminalKeepRequest.Response {
        guard identity?.supports(DaemonCapabilities.shared.terminalReap) == true else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.terminalReap])
        }
        return try await request(SetTerminalKeepRequest(target, keep: keep))
    }

    /// Adds a tab showing the live terminal `terminal` (`term_…`) at `index`
    /// in the pane at `path` (`terminal.project`, resource API v2). Works on
    /// a terminal with no tab while it is still alive; fails with the
    /// daemon's `selector.not_found` once it ended.
    @discardableResult
    public func projectTerminal(_ terminal: ResourceID, into path: PaneResourcePath, index: Int,
                                name: String? = nil) async throws -> ProjectedTab {
        var params: [String: JSONValue] = [
            "terminal": .string(terminal.rawValue),
            "destination_workspace": .string(path.workspace.rawValue),
            "destination_screen": .string(path.screen.rawValue),
            "destination_pane": .string(path.pane.rawValue),
            "index": .number(Double(max(0, index))),
        ]
        if let name { params["name"] = .string(name) }
        let key = "cmux-next-project-" + UUID().uuidString.lowercased()
        let fields = params
        let result = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "terminal.project", params: fields, idempotencyKey: key)
        }, as: ResourceMutationResult<ProjectedTab>.self)
        return result.value
    }
}
