public import CmuxNextSettings

/// `workspace.expect_window` (#32989): the `cmux` CLI and MCP announce a `workspace create`
/// before they send it to the daemon, so the workspace opens in the right window. The daemon
/// has no windows; its workspace-added delta echoes the create's idempotency key
/// (`mutation_id`), and the app claims that workspace for the window named here as the delta
/// lands (`WorkspaceClaims.claimExpected`), before membership would give it to the most
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
/// The reply is ``reply``: `{"window": "win_…"}`, or `{"window": null}` when no window is known
/// (the create then goes where it did before: the most recent window).
public struct ControlWorkspaceWindowExpectation: Sendable, Equatable {
    public static let method = "workspace.expect_window"
    static let parameters: Set<String> = ["idempotency_key", "window", "caller", "focus", "origin", "after"]

    /// The create's idempotency key.
    public var key: String
    /// The window's record id (`ControlWindowInfo.id`); nil when none is known.
    public var window: String?
    /// The window selects the workspace once it lands (`--focus`).
    public var shows: Bool

    /// Reads `params` against `topology`; `isOpen` says whether a window record id is open.
    public init(params: [String: JSONValue], in topology: ControlTopology, isOpen: (String) -> Bool) throws {
        if let unknown = params.keys.sorted().first(where: { !Self.parameters.contains($0) }) {
            throw ControlError.invalidParams("\(Self.method) does not take params.\(unknown)")
        }
        guard let key = params["idempotency_key"]?.stringValue, !key.isEmpty, key.count <= 200 else {
            throw ControlError.invalidParams("\(Self.method) needs params.idempotency_key, the create's key")
        }
        self.key = key
        shows = params["focus"]?.boolValue == true
        if let named = params["window"]?.stringValue {
            guard let info = topology.windows.first(where: { $0.id == named || $0.publicID == named }), isOpen(info.id) else {
                throw ControlError(code: "not_found", message: "no open window \(named)", data: ["window": .string(named)])
            }
            window = info.id
        } else {
            let callers = try ControlCallerWindow(params: params, in: topology)
            window = callers.map(\.id).flatMap { isOpen($0) ? $0 : nil }
        }
    }

    public var reply: JSONValue {
        ["window": window.map { .string(ControlWindowInfo.publicID(forKey: $0)) } ?? .null]
    }
}
