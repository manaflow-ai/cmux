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
    ("target_surface_id", "Surface"),
    ("target_pane_id", "Pane"),
    // Relative selectors: a stale one here is silently dropped and the
    // mutation (reorder, move) still runs, at a position the caller did not
    // ask for.
    ("before_surface_id", "Surface"),
    ("after_surface_id", "Surface"),
    ("before_workspace_id", "Workspace"),
    ("after_workspace_id", "Workspace"),
    ("reference_workspace_id", "Workspace"),
    ("before_group_id", "Workspace group"),
    ("after_group_id", "Workspace group"),
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
    /// Returns an error when a request names a target that is not a usable
    /// identifier at all: present and non-null, but not a non-empty string.
    /// A number, an object, or `"   "` would otherwise read as "no target"
    /// and hand the command its focused-object fallback.
    ///
    /// `nonisolated` and registry-free, so both dispatch lanes can run it
    /// without a main-actor hop.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The error result to return instead of running the command.
    nonisolated func malformedTargetError(_ request: ControlRequest) -> ControlCallResult? {
        if resolvesTargetOutsideTheHandleRegistry(method: request.method) { return nil }
        for (key, noun) in handleTargetParamNouns {
            guard hasNonNull(request.params, key) else { continue }
            guard string(request.params, key) == nil else { continue }
            return .err(
                code: "invalid_params",
                message: "\(noun) target \(key) must be a non-empty id or handle ref",
                data: nil
            )
        }
        return nil
    }

    /// Whether any explicit target needs the handle registry to resolve, i.e.
    /// is a string that is not already a UUID. Lets the worker lane skip its
    /// main-actor preflight hop for the common all-UUID request.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: `true` when a registry lookup is required.
    nonisolated func targetsNeedHandleRegistry(_ request: ControlRequest) -> Bool {
        if resolvesTargetOutsideTheHandleRegistry(method: request.method) { return false }
        return handleTargetParamNouns.contains { key, _ in
            guard let raw = string(request.params, key) else { return false }
            return UUID(uuidString: raw) == nil
        }
    }

    /// Returns a `not_found` error when a request names a target through a
    /// handle ref this coordinator cannot resolve, or `nil` when every
    /// explicit target resolves.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The error result to return instead of running the command.
    func unresolvedTargetError(_ request: ControlRequest) -> ControlCallResult? {
        if let malformed = malformedTargetError(request) { return malformed }
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

    /// The worker lane's twin of ``unresolvedTargetError(_:)``: the pure
    /// checks run on the calling socket-worker thread, and the registry lookup
    /// takes the same `controlResolveOnMain` hop (and known-ref refresh) the
    /// worker-lane bodies use — only when a target actually needs it.
    ///
    /// A ref-carrying worker request therefore costs one extra main hop, but
    /// not an extra topology sweep: it uses the refresh-free
    /// `controlMainSyncWithoutRefreshingRefs` seam, since a ref the caller
    /// holds was necessarily minted before. A UUID target skips the hop
    /// altogether, so the typing-latency paths (`surface.send_text` /
    /// `send_key` from shell integration and hooks, which carry UUIDs) are
    /// untouched.
    ///
    /// - Parameters:
    ///   - request: The decoded request envelope.
    ///   - context: The live app seam.
    /// - Returns: The error result to return instead of running the command.
    nonisolated func unresolvedTargetErrorOnWorkerLane(
        _ request: ControlRequest,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult? {
        if let malformed = malformedTargetError(request) { return malformed }
        guard targetsNeedHandleRegistry(request), let context else { return nil }
        return context.controlMainSyncWithoutRefreshingRefs { _ in
            self.unresolvedTargetError(request)
        }
    }
}
