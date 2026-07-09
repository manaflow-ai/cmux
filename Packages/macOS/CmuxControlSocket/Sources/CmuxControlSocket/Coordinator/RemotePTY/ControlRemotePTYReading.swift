public import Foundation

/// The seam through which ``ControlRemotePTYWorker`` reaches the live window /
/// workspace / surface graph to resolve a `workspace.remote.pty_*` command's
/// target controller, without the package importing the app target.
///
/// ## Why the seam
///
/// The legacy `v2WorkspaceRemotePTY*` bodies resolved their target through
/// `v2ResolveRemotePTYTarget` / `v2ResolveRemotePTYTargetWaitingForController` /
/// the `all_workspaces` enumeration, all of which read live app state on the main
/// actor: the `AppDelegate` window list, each `Workspace`'s remote controller and
/// moved-surface matching, the `TabManager` ownership graph, the handle-ref
/// vocabulary (`v2Ref` / `v2ResolveHandleRef`), and the workspace/surface UUID
/// coercion (`v2UUID`, which itself resolves a handle ref on main). None of that
/// can move into this package. This seam inverts it: the package owns the
/// protocol and the command bodies; the app conformer
/// (`TerminalControllerRemotePTYReading`) does the main-actor resolution and
/// hands back a Sendable ``ControlRemotePTYTarget`` (controller bound behind
/// ``ControlRemotePTYControlling``, refs pre-encoded as ``JSONValue``).
///
/// ## Isolation
///
/// `Sendable` and synchronous: the legacy resolution ran on the nonisolated
/// socket-worker lane and hopped to the main actor internally with `v2MainSync`
/// (`DispatchQueue.main.sync`). The conformer keeps that exact shape — each
/// member blocks the worker thread on a synchronous main hop — so there is no new
/// suspension point and the availability-condition wait
/// (``resolveTargetWaitingForController(params:requestedWorkspaceID:preferredSurfaceID:deadlineUnixSeconds:)``)
/// blocks the worker thread on the app's `NSCondition` exactly as before.
public protocol ControlRemotePTYReading: Sendable {
    /// Resolves the requested `workspace_id` to a UUID, mirroring the legacy
    /// `v2RequestedRemotePTYWorkspaceID`: returns the resolved UUID (`nil` when
    /// absent), or an `invalid_params` error when a non-null `workspace_id` was
    /// supplied but could not be resolved (raw UUID or handle ref).
    ///
    /// - Parameter params: The raw request params.
    /// - Returns: The resolved workspace UUID and/or a terminal error.
    func requestedWorkspaceID(
        params: [String: JSONValue]
    ) -> (workspaceID: UUID?, error: ControlCallResult?)

    /// Resolves the requested `surface_id` to a UUID, mirroring the legacy
    /// `v2RequestedRemotePTYSurfaceID`: returns the resolved UUID (`nil` when
    /// absent), or an `invalid_params` error when a non-null `surface_id` was
    /// supplied but could not be resolved.
    ///
    /// - Parameter params: The raw request params.
    /// - Returns: The resolved surface UUID and/or a terminal error.
    func requestedSurfaceID(
        params: [String: JSONValue]
    ) -> (surfaceID: UUID?, error: ControlCallResult?)

    /// Resolves the target workspace's controller + refs, mirroring the legacy
    /// `v2ResolveRemotePTYTarget`. Reads the live graph on the main actor,
    /// applies the moved-surface allowance, and returns either a target or a
    /// terminal error (`invalid_params` for an `allow_moved_surface` /
    /// `surface_id`-mismatch, `not_found` for a missing workspace).
    ///
    /// - Parameters:
    ///   - params: The raw request params (read for `allow_moved_surface`,
    ///     `session_id`, and the fallback tab-manager routing keys).
    ///   - requestedWorkspaceID: The pre-resolved `workspace_id`, if any.
    ///   - preferredSurfaceID: The surface to prefer when locating the workspace.
    /// - Returns: The resolved target and/or a terminal error.
    func resolveTarget(
        params: [String: JSONValue],
        requestedWorkspaceID: UUID?,
        preferredSurfaceID: UUID?
    ) -> ControlRemotePTYTargetResolution

    /// Resolves the target, blocking until the workspace's controller becomes
    /// available or the deadline passes, mirroring the legacy
    /// `v2ResolveRemotePTYTargetWaitingForController` (the
    /// `remotePTYControllerAvailabilityCondition` generation wait). Used only by
    /// `workspace.remote.pty_bridge` with `wait_for_ready`.
    ///
    /// - Parameters:
    ///   - params: The raw request params.
    ///   - requestedWorkspaceID: The pre-resolved `workspace_id`, if any.
    ///   - preferredSurfaceID: The surface to prefer when locating the workspace.
    ///   - deadlineUnixSeconds: The absolute wait deadline as a Unix timestamp
    ///     (`Date.timeIntervalSince1970`), so the worker owns the deadline math
    ///     and the package carries no `Date`.
    /// - Returns: The resolved target and/or a terminal error.
    func resolveTargetWaitingForController(
        params: [String: JSONValue],
        requestedWorkspaceID: UUID?,
        preferredSurfaceID: UUID?,
        deadlineUnixSeconds: Double
    ) -> ControlRemotePTYTargetResolution

    /// Enumerates every remote workspace across every window as a target,
    /// mirroring the legacy `all_workspaces` branch of
    /// `v2WorkspaceRemotePTYSessions`. Reads the live window/workspace graph on
    /// the main actor and binds each workspace's controller behind
    /// ``ControlRemotePTYControlling``.
    ///
    /// - Returns: One target per remote workspace, in window/tab order.
    func allWorkspaceTargets() -> [ControlRemotePTYTarget]
}