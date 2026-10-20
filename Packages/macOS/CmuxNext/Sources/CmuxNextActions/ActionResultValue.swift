/// One field of the value an action's work hands back to a caller that
/// waits for it (``ActionRegistry/track(result:)``). The control socket's
/// `action.run` answers the fields as its `result` object, so a CLI verb or
/// MCP tool gets data back from an action (a screenshot's path and size).
public nonisolated enum ActionResultValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

/// The asynchronous work of an action that produces a value: its fields on
/// success, else the failure the caller reports.
public typealias ActionResultWork = Task<Result<[String: ActionResultValue], ActionWorkFailure>, Never>
