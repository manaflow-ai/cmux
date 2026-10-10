public import Foundation

/// Sample data for live previews of apps that are not installed: the app's
/// real code runs, but it sees made-up agents and workspaces and can change
/// nothing (no grant exists before install). Network and actions refuse.
public nonisolated struct AppPreviewSink: AppOperationSink {
    public init() {}

    /// Sample agents, updated a few minutes before `now`.
    public static func agents(now: Date = Date()) -> AppJSON {
        let ms = { (minutes: Double) in AppJSON.number((now.timeIntervalSince1970 - minutes * 60) * 1000) }
        return [
        ["id": "a1", "state": "blocked", "terminal_id": "term_1", "source": "claude", "updated_at_ms": ms(3),
             "extra": ["name": "Fix flaky sidebar test"]],
        ["id": "a2", "state": "working", "terminal_id": "term_2", "source": "codex", "updated_at_ms": ms(1), "extra": ["name": "Port runtime to QuickJS"]],
        ["id": "a3", "state": "working", "terminal_id": "term_3", "source": "claude", "updated_at_ms": ms(12), "extra": ["name": "Review PR 16740"]],
        ["id": "a4", "state": "idle", "terminal_id": "term_4", "source": "shell", "updated_at_ms": ms(95), "extra": ["name": "docs"]],
        ]
    }

    public static let workspaces: AppJSON = [
        ["id": "ws_1", "name": "cmux", "unread": 2], ["id": "ws_2", "name": "cmux-tui", "unread": 0],
    ]

    public func perform(_ request: AppOperationRequest) async -> Result<AppOperationResult, AppOperationError> {
        switch request.op {
        case "agent.list": .success(AppOperationResult(value: Self.agents()))
        case "workspace.list": .success(AppOperationResult(value: Self.workspaces))
        case "tab.list", "notification.list": .success(AppOperationResult(value: []))
        case "app.storage.get": .success(AppOperationResult(value: .null))
        case "app.storage.keys": .success(AppOperationResult(value: []))
        default: .failure(AppOperationError(code: "preview.readOnly", message: "Install the app to use \(request.op)."))
        }
    }
}
