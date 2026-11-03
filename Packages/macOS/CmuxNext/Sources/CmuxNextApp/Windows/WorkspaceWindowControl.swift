import CmuxNextControl
import CmuxNextDaemon

/// `workspace.expect_window` (#32989): the `cmux` CLI and MCP announce a `workspace create`
/// before they send it to the daemon, so the workspace opens in the right window. The daemon
/// has no windows; its workspace-added delta echoes the create's idempotency key
/// (`mutation_id`), and the app claims that workspace for the window named here as the delta
/// lands (`WindowManager.claimExpectedCreate`), before membership would give it to the most
/// recent window.
///
/// Params:
/// - `idempotency_key` (required): the create's key.
/// - `window`: the window it opens in (`win_…` or its record id), as `--window` names it. An
///   unknown or closed window is refused, so an explicit target never lands somewhere else.
/// - `caller`: who creates it (the CLI adds it, app.rs `with_caller`). Without `window`, a
///   Chief turn's workspace opens in the window the person prompted the Chief from, and any
///   other caller's in the window that lists the caller's own workspace.
/// - `focus` (default false): the window selects it once it lands; otherwise it is filed
///   without changing what the window shows.
///
/// Replies `{"window": "win_…"}`, or `{"window": null}` when no window is known (the create
/// then goes where it did before: the most recent window).
enum WorkspaceWindowControl {
    static let method = "workspace.expect_window"
    static let parameters: Set<String> = ["idempotency_key", "window", "caller", "focus", "origin", "after"]

    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .mainActor(method) { [weak services] call in
                guard let services else { return .value(["window": .null]) }
                return .value(try expect(call.params, topology: call.snapshot.topology, windows: services.windows))
            },
        ]
    }

    static func expect(_ params: [String: JSONValue], topology: ControlTopology, windows: WindowManager) throws -> JSONValue {
        if let unknown = params.keys.sorted().first(where: { !parameters.contains($0) }) {
            throw ControlError.invalidParams("\(method) does not take params.\(unknown)")
        }
        guard let key = params["idempotency_key"]?.stringValue, !key.isEmpty, key.count <= 200 else {
            throw ControlError.invalidParams("\(method) needs params.idempotency_key, the create's key")
        }
        let window: String?
        if let named = params["window"]?.stringValue {
            guard let info = topology.windows.first(where: { $0.id == named || $0.publicID == named }),
                  windows.registry.value.window(info.id)?.isOpen == true else {
                throw ControlError(code: "not_found", message: "no open window \(named)",
                                   data: ["window": .string(named)])
            }
            window = info.id
        } else {
            window = try ControlCallerWindow(params: params, in: topology)?.id
        }
        guard let window, windows.registry.value.window(window)?.isOpen == true else { return ["window": .null] }
        windows.expectedCreates.expect(key: key, window: window, shows: params["focus"]?.boolValue == true)
        return ["window": .string(ControlWindowInfo.publicID(forKey: window))]
    }
}
