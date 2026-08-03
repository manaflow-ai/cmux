internal import Foundation

/// The id params that select an object to act on, with the noun used in the
/// error message.
private let handleTargetParamNouns: [(key: String, noun: String)] = [
    ("window_id", "Window"),
    ("group_id", "Workspace group"),
    ("workspace_id", "Workspace"),
    ("surface_id", "Surface"),
    ("terminal_id", "Surface"),
    ("tab_id", "Surface"),
    ("pane_id", "Pane"),
]

/// Whether a method resolves its own target instead of going through the
/// handle registry, so the preflight must leave its params alone.
///
/// `debug.*` verbs take the legacy v1 `<id|idx>` argument form
/// (`debug.terminal.read_text 0`) and hand the raw string to the app-side v1
/// resolver. The mobile-host verbs (`mobile.*` / `terminal.*` /
/// `chat.sessions.dump`) are pass-throughs whose seam runs the legacy body
/// app-side; none of them mint or read `kind:N` refs.
private func resolvesTargetOutsideTheHandleRegistry(method: String) -> Bool {
    method.hasPrefix("debug.")
        || method.hasPrefix("mobile.")
        || method.hasPrefix("terminal.")
        || method.hasPrefix("chat.")
}

/// Dispatch preflight that rejects explicit targets that resolve to nothing
/// (issue #9410).
///
/// Every routing/target param (`window_id`, `workspace_id`, `surface_id`, …)
/// accepts either a UUID or a `kind:N` ref minted by ``ControlHandleRegistry``.
/// Anything else — a stale ref, a mistyped kind (`surafce:12`), a malformed
/// ordinal (`surface:not-a-number`) — used to parse to `nil`, which is
/// indistinguishable from "the caller passed no target": commands then fell
/// back to the focused/selected object. For a destructive op such as
/// `surface.close` or `surface.respawn` that turned a stale or typo'd ref into
/// a roulette close of whatever happened to be selected.
///
/// An explicit target that cannot be found means the caller's model of the
/// world is wrong, which is exactly when acting on some other object is most
/// dangerous, so the request fails closed with `not_found` and no side effect.
///
/// The preflight runs after the dispatch preamble's known-ref refresh, so the
/// registry already holds a ref for every live window, workspace, pane, and
/// surface: a ref it cannot resolve is definitively stale. A UUID target is
/// accepted here and keeps its existing per-command not-found handling, which
/// reports the id the caller passed.
extension ControlCommandCoordinator {
    /// Returns a `not_found` error when a request names a target this
    /// coordinator cannot resolve, or `nil` when every explicit target
    /// resolves.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The error result to return instead of running the command.
    func unresolvedTargetError(_ request: ControlRequest) -> ControlCallResult? {
        if resolvesTargetOutsideTheHandleRegistry(method: request.method) { return nil }
        for (key, noun) in handleTargetParamNouns {
            guard let raw = string(request.params, key) else { continue }
            guard UUID(uuidString: raw) == nil else { continue }
            guard handles.uuid(forRef: raw) == nil else { continue }
            return .err(
                code: "not_found",
                message: "\(noun) not found",
                data: .object([key: .string(raw)])
            )
        }
        return nil
    }
}
