public import Foundation

/// The system/misc-domain slice of the control-command seam (a constituent of
/// the ``ControlCommandContext`` umbrella): `system.identify`, `system.tree`,
/// `auth.login`, `session.restore_previous`, `settings.open`, `feedback.open`,
/// `extension.sidebar.snapshot`, `workspace.action`, `surface.action` /
/// `tab.action`, `surface.drag_to_split` / `surface.split_off`, and the
/// DEBUG-only `mobile.dev_stack_auth.configure`.
///
/// Every method is `@MainActor`: the conformer (the interim composition owner)
/// and the coordinator both live on the main actor, so these are plain
/// in-isolation calls.
@MainActor
public protocol ControlSystemContext: AnyObject {
    /// The fully-shaped `system.identify` payload (the still-shared app-side
    /// `v2Identify`, which also feeds `system.top` / `system.memory` and the
    /// task-manager snapshot), bridged to a JSON value.
    ///
    /// - Parameter params: The identify params (`caller`, `window_id`, …).
    /// - Returns: The identify payload object.
    func controlSystemIdentify(params: [String: JSONValue]) -> JSONValue

    /// Walks the main windows for `system.tree`, mirroring the legacy
    /// default-window / all-windows / workspace-filter selection.
    ///
    /// - Parameters:
    ///   - requestedWindowID: The explicit `window_id`, if any.
    ///   - includeAllWindows: Whether `all_windows` was set.
    ///   - focusedWindowID: The focused window from the identify payload.
    ///   - workspaceFilter: The explicit `workspace_id` filter, if any.
    /// - Returns: The matched window nodes plus the found-flags.
    func controlSystemTreeWindows(
        requestedWindowID: UUID?,
        includeAllWindows: Bool,
        focusedWindowID: UUID?,
        workspaceFilter: UUID?
    ) -> ControlSystemTreeResolution

    /// Whether the socket access mode requires password auth, for the
    /// `auth.login` payload's `required` field.
    func controlAuthPasswordRequired() -> Bool

    /// Reopens the previous session snapshot for `session.restore_previous`.
    ///
    /// - Returns: The restore resolution (failure carries the app-localized
    ///   message).
    func controlSessionRestorePrevious() -> ControlSessionRestoreResolution

    /// Validates the target and schedules the settings window for
    /// `settings.open`.
    ///
    /// - Parameters:
    ///   - targetRaw: The raw `target` param, if any.
    ///   - requestedActivate: The requested `activate` flag (the app applies
    ///     the focus-allowance policy).
    /// - Returns: The open resolution.
    func controlSettingsOpen(targetRaw: String?, requestedActivate: Bool) -> ControlSettingsOpenResolution

    /// Schedules the feedback composer for `feedback.open`.
    ///
    /// - Parameters:
    ///   - workspaceID: The explicit `workspace_id`, if any.
    ///   - windowID: The explicit `window_id`, if any.
    ///   - requestedActivate: The requested `activate` flag (the app applies
    ///     the focus-allowance policy).
    func controlFeedbackOpen(workspaceID: UUID?, windowID: UUID?, requestedActivate: Bool)

    /// Snapshots the routed window's workspaces for
    /// `extension.sidebar.snapshot`.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: The snapshot, or `nil` when no TabManager resolved.
    func controlExtensionSidebarSnapshot(routing: ControlRoutingSelectors) -> ControlExtensionSidebarSnapshot?

    /// Runs one `workspace.action` mutation, delegating to the shared
    /// app-side `v2WorkspaceAction` (also driven by the mobile host's gated
    /// `workspace.action` RPC, so the body stays app-side) and bridging its
    /// fully-shaped result.
    ///
    /// - Parameter params: The raw command params.
    /// - Returns: The fully shaped call result.
    func controlWorkspaceAction(params: [String: JSONValue]) -> ControlCallResult

    /// Runs one `surface.action` / `tab.action` mutation in the legacy order.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - actionKey: The normalized action key, or `nil` when missing.
    ///   - title: The trimmed `title` param, if any.
    ///   - titleSource: The trimmed `title_source` param, if any.
    ///   - rawURL: The trimmed `url` param, if any.
    ///   - surfaceID: The explicit `surface_id` / `tab_id`, if any.
    ///   - requestedFocus: The requested `focus` flag (the app applies the
    ///     focus-allowance policy).
    ///   - moveParams: The raw request params, passed through to the
    ///     still-app-side move-to-new-workspace family.
    /// - Returns: The action resolution.
    func controlTabAction(
        routing: ControlRoutingSelectors,
        actionKey: String?,
        title: String?,
        titleSource: String?,
        rawURL: String?,
        surfaceID: UUID?,
        requestedFocus: Bool,
        moveParams: [String: JSONValue]
    ) -> ControlTabActionResolution

    /// Splits a surface off into its own pane for `surface.split_off` /
    /// `surface.drag_to_split`, delegating to the shared app-side
    /// `v2SurfaceSplitOff` (also driven by the v1 `drag_surface_to_split`
    /// command) and bridging its fully-shaped result.
    ///
    /// - Parameter params: The raw command params.
    /// - Returns: The fully shaped call result.
    func controlSurfaceSplitOff(params: [String: JSONValue]) -> ControlCallResult

    #if DEBUG
    /// Configures (or clears, with `nil`) the accepted dev Stack auth token
    /// for the DEBUG-only `mobile.dev_stack_auth.configure`.
    ///
    /// - Parameter token: The token to accept, or `nil` to disable.
    func controlMobileDevStackAuthSetToken(_ token: String?)
    #endif
}
