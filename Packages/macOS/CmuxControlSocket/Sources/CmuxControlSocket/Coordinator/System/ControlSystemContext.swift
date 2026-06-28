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

    /// Builds one `system.top` / `system.memory` workspace node from live
    /// `Workspace` state (panes, surfaces, browser webviews, status tags),
    /// mirroring the legacy `v2TopWorkspaceNode` tree walk. The coordinator
    /// shapes the returned node into the payload dictionary via
    /// ``ControlCommandCoordinator/systemTopWorkspacePayload(_:)``.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace to snapshot.
    ///   - index: The workspace's index within its window's tab list.
    ///   - selected: Whether this is the window's selected workspace.
    /// - Returns: The workspace node, or `nil` when the workspace no longer
    ///   resolves.
    func controlSystemTopWorkspaceNode(
        workspaceID: UUID,
        index: Int,
        selected: Bool
    ) -> ControlSystemTopWorkspaceNode?

    /// Whether the socket access mode requires password auth, for the
    /// `auth.login` payload's `required` field.
    func controlAuthPasswordRequired() -> Bool

    /// The server's current socket path, for the `system.capabilities`
    /// `socket_path` field (the live `socketServer.currentSocketPath`).
    func controlSystemSocketPath() -> String

    /// The server access mode's raw value, for the `system.capabilities`
    /// `access_mode` field (the live `socketServer.accessMode.rawValue`).
    func controlSystemAccessModeRawValue() -> String

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

    /// Runs one `surface.action` / `tab.action` mutation in the legacy order.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - actionKey: The normalized action key, or `nil` when missing.
    ///   - title: The trimmed `title` param, if any.
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

    // MARK: - v1 line-protocol help body

    /// The v1 `help` body: the full human-readable command-reference text (with
    /// its DEBUG-only trailing section). Returned verbatim — byte-identical to
    /// the legacy `TerminalController.helpText`. The witness carries the text
    /// app-side because the DEBUG/release split and the exact wording are frozen
    /// app-resident copy.
    ///
    /// - Returns: The raw v1 help text.
    func controlHelpTextV1() -> String
}
