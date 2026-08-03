internal import Foundation

/// Dispatch preflight that rejects stale `kind:N` handle refs (issue #9410).
///
/// Every routing/target param (`window_id`, `workspace_id`, `surface_id`, …)
/// accepts either a UUID or a `kind:N` ref minted by ``ControlHandleRegistry``.
/// A ref that the registry does not know used to resolve to `nil`, which is
/// indistinguishable from "the caller passed no target": commands then fell
/// back to the focused/selected object. For a destructive op such as
/// `surface.close` or `surface.respawn` that turned a stale or typo'd ref into
/// a roulette close of whatever happened to be selected.
///
/// An explicit target that cannot be found means the caller's model of the
/// world is wrong, which is exactly when acting on some other object is most
/// dangerous, so the request fails with `not_found` and no side effect.
///
/// The preflight runs after the dispatch preamble's known-ref refresh, so the
/// registry already holds a ref for every live window, workspace, pane, and
/// surface: an unresolvable ref is definitively stale. It only inspects
/// strings shaped like a ref (`<known kind>:<digits>`, plus the `tab:N` alias
/// for `surface:N`); UUID targets keep their existing per-command not-found
/// handling, and non-ref strings are left to their command.
extension ControlCommandCoordinator {
    /// The id params that select an object to act on, with the noun used in
    /// the error message.
    private static let handleRefParamNouns: [(key: String, noun: String)] = [
        ("window_id", "Window"),
        ("group_id", "Workspace group"),
        ("workspace_id", "Workspace"),
        ("surface_id", "Surface"),
        ("terminal_id", "Surface"),
        ("tab_id", "Surface"),
        ("pane_id", "Pane"),
    ]

    /// Whether a string is shaped like a handle ref this registry mints.
    private static func isHandleRefShaped(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        guard let separator = lowered.lastIndex(of: ":") else { return false }
        let kind = String(lowered[lowered.startIndex..<separator])
        let ordinal = lowered[lowered.index(after: separator)...]
        guard !ordinal.isEmpty, ordinal.allSatisfy({ $0.isNumber }) else { return false }
        if kind == "tab" { return true }
        return ControlHandleKind(rawValue: kind) != nil
    }

    /// Returns a `not_found` error when a request names a target through a
    /// handle ref that no longer exists, or `nil` when every ref-shaped target
    /// resolves.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The error result to return instead of running the command.
    func staleHandleRefError(_ params: [String: JSONValue]) -> ControlCallResult? {
        for (key, noun) in Self.handleRefParamNouns {
            guard let raw = string(params, key) else { continue }
            guard UUID(uuidString: raw) == nil else { continue }
            guard Self.isHandleRefShaped(raw) else { continue }
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
