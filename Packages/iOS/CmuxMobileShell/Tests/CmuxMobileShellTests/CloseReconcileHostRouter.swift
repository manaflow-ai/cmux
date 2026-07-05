import CMUXMobileCore
import Foundation

// Scripted Mac for issue #6349: `workspace.close` succeeds, but
// `workspace.list` can keep returning the closed workspace until catch-up.
actor CloseReconcileHostRouter {
    private(set) var closeRequestCount = 0
    /// Once set, `workspace.list` stops reporting the closed workspace.
    private var caughtUp = false
    func markCaughtUp() { caughtUp = true }
    private let capabilities = [
        "events.v1",
        "workspace.actions.v1",
        "workspace.read_state.v1",
        "workspace.close.v1",
        "terminal.render_grid.v1",
        "terminal.replay.v1",
    ]

    func response(method: String?, id: String?) async -> Data? {
        switch method {
        case "workspace.list", "mobile.workspace.list":
            return try? Self.resultFrame(id: id, result: ["workspaces": Self.workspaceList(includeClosed: !caughtUp)])
        case "workspace.close":
            closeRequestCount += 1
            return try? Self.resultFrame(id: id, result: [
                "closed": true,
                "workspace_id": "live-workspace",
            ])
        case "mobile.host.status":
            return try? Self.resultFrame(id: id, result: [
                "terminal_fidelity": "render_grid",
                "capabilities": capabilities,
            ])
        case "mobile.events.subscribe":
            return try? Self.resultFrame(id: id, result: [
                "stream_id": "test-stream",
                "topics": ["workspace.updated", "terminal.render_grid"],
                "already_subscribed": false,
            ])
        case "mobile.events.unsubscribe", "mobile.terminal.replay", "mobile.terminal.viewport":
            return try? Self.resultFrame(id: id, result: [:])
        default:
            return try? Self.errorFrame(id: id, message: "Unexpected method \(method ?? "nil")")
        }
    }

    private static func workspaceList(includeClosed: Bool) -> [[String: Any]] {
        var list = [workspaceEntry(id: "workspace-b", title: "Workspace B", selected: true, terminalID: "terminal-b")]
        if includeClosed {
            list.insert(
                workspaceEntry(id: "live-workspace", title: "Workspace A", selected: false, terminalID: "live-terminal"),
                at: 0)
        }
        return list
    }

    private static func workspaceEntry(
        id: String,
        title: String,
        selected: Bool,
        terminalID: String
    ) -> [String: Any] {
        [
            "id": id,
            "title": title,
            "current_directory": "/Users/test/project",
            "is_selected": selected,
            "terminals": [
                [
                    "id": terminalID,
                    "title": "Terminal",
                    "current_directory": "/Users/test/project",
                    "is_ready": true,
                    "is_focused": selected,
                ],
            ],
        ]
    }

    private static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    private static func errorFrame(id: String?, message: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": ["message": message],
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}
