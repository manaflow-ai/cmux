public import Foundation

/// The surface-domain slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella).
///
/// The app target (today `TerminalController`, the interim composition owner)
/// conforms by reading live `TabManager` / `Workspace` / `TerminalPanel` /
/// `BrowserPanel` state, the Ghostty surfaces, the `TerminalSurfaceRegistry`,
/// and the `SurfaceResumeApprovalStore`. Every method is `@MainActor` because its
/// conformer and the coordinator both live on the main actor, so these are plain
/// in-isolation calls — the per-read `v2MainSync` hops the legacy command bodies
/// used disappear once the domain moves onto the coordinator.
///
/// No app types cross the seam: reads return `Control*` snapshot values, mutations
/// take pre-parsed selectors/ids and return small Sendable resolution enums, and
/// every blocking `NSAlert` and `String(localized:)` resolves inside the app
/// conformance (app bundle). The lone exception is ``controlDebugTerminals`` — its
/// payload is dozens of irreducibly app-coupled `NSWindow`/`NSView`/Ghostty
/// pointer fields, so the app returns it as a bridged ``JSONValue`` (the same
/// single-method passthrough `workspace.remote.configure` uses).
@MainActor
public protocol ControlSurfaceContext: AnyObject {
    /// Whether a TabManager resolves for surface routing, used to distinguish the
    /// `unavailable` failure from the `not_found` failure.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: Whether a TabManager resolved.
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool

    // MARK: - list / current / health

    /// Snapshots the resolved workspace's surfaces for `surface.list`.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: The list snapshot, or `nil` when no workspace resolves.
    func controlSurfaceList(routing: ControlRoutingSelectors) -> ControlSurfaceListSnapshot?

    /// Snapshots the current surface for `surface.current`.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: The current snapshot, or `nil` when no workspace resolves.
    func controlSurfaceCurrent(routing: ControlRoutingSelectors) -> ControlSurfaceCurrentSnapshot?

    /// Snapshots surface render health for `surface.health`.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: The health snapshot, or `nil` when no workspace resolves.
    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot?

    /// The app-bundle-resolved localized error strings for `surface.respawn`. The
    /// app resolves each `String(localized:)` with the identical key + default
    /// value so the package never binds them to the wrong bundle.
    ///
    /// - Returns: The respawn strings.
    func controlSurfaceRespawnStrings() -> ControlSurfaceRespawnStrings

    // MARK: - focus / split / respawn / create / close

    /// Focuses a surface for `surface.focus`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The surface to focus.
    /// - Returns: The focus resolution.
    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution

    /// Creates a split surface for `surface.split`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - inputs: The pre-parsed (and pre-validated) split inputs.
    /// - Returns: The split resolution.
    func controlSurfaceSplit(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceSplitInputs
    ) -> ControlSurfaceSplitResolution

    /// Respawns a terminal surface for `surface.respawn`. The coordinator selects
    /// each localized error message from ``controlSurfaceRespawnStrings()``; this
    /// returns only the discriminator and ids.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - inputs: The pre-parsed (and pre-validated, including the resolved
    ///     focus) respawn inputs.
    /// - Returns: The respawn resolution.
    func controlSurfaceRespawn(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceRespawnInputs
    ) -> ControlSurfaceRespawnResolution

    /// Creates a surface for `surface.create`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - inputs: The pre-parsed create inputs.
    /// - Returns: The create resolution.
    func controlSurfaceCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceCreateInputs
    ) -> ControlSurfaceCreateResolution

    /// Closes a surface for `surface.close`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, or `nil` for the focused surface.
    /// - Returns: The close resolution.
    func controlSurfaceClose(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceCloseResolution

    // MARK: - move / reorder

    /// Moves a surface for `surface.move`, delegating to the shared
    /// surface-move logic, and bridges the result to a ``ControlCallResult``.
    ///
    /// The whole body is app-typed end to end (it walks windows/workspaces/panes
    /// and mutates Bonsplit), so the coordinator passes the raw params through and
    /// the app returns the fully shaped result (forwarding the still-app-side
    /// `v2SurfaceMove`, exactly as `pane.join` does).
    ///
    /// - Parameter params: The raw command params.
    /// - Returns: The fully shaped call result.
    func controlSurfaceMove(params: [String: JSONValue]) -> ControlCallResult

    /// Reorders a surface within its pane for `surface.reorder`.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface to reorder.
    ///   - inputs: The pre-parsed (and pre-validated, exactly-one-target) reorder
    ///     inputs.
    ///   - requestedFocus: Whether the request asked to focus the surface.
    /// - Returns: The reorder resolution.
    func controlSurfaceReorder(
        surfaceID: UUID,
        inputs: ControlSurfaceReorderInputs,
        requestedFocus: Bool
    ) -> ControlSurfaceReorderResolution

    // MARK: - refresh / clear_history / trigger_flash

    /// Force-refreshes every terminal surface in the workspace for
    /// `surface.refresh`.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: The refresh resolution.
    func controlSurfaceRefresh(routing: ControlRoutingSelectors) -> ControlSurfaceRefreshResolution

    /// Clears terminal history for `surface.clear_history`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The parsed `surface_id`, or `nil` (focused-surface fallback
    ///     only when the param was absent).
    ///   - hasSurfaceIDParam: Whether a `surface_id` param was present at all —
    ///     present-but-unparseable must error, not silently fall back to the
    ///     focused surface (legacy `params["surface_id"] != nil` guard).
    /// - Returns: The clear-history resolution.
    func controlSurfaceClearHistory(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool
    ) -> ControlSurfaceClearHistoryResolution

    /// Triggers the focus flash for `surface.trigger_flash`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, or `nil` for the focused surface.
    /// - Returns: The trigger-flash resolution.
    func controlSurfaceTriggerFlash(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceTriggerFlashResolution

    /// The app-bundle-resolved localized terminal-input error strings, shared by
    /// `surface.send_text` and `surface.send_key`. The app resolves each
    /// `String(localized:)` so the package never binds them to the wrong bundle.
    /// `nonisolated`: a pure, thread-safe bundle lookup, called by the
    /// worker-lane send bodies' off-main reply shaping.
    ///
    /// - Returns: The input strings.
    nonisolated func controlSurfaceInputStrings() -> ControlSurfaceInputStrings

    // MARK: - send_text / send_key

    /// Sends literal text for `surface.send_text`. The coordinator selects each
    /// localized error message from ``controlSurfaceInputStrings()``.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, or `nil` for the focused surface.
    ///   - hasSurfaceIDParam: Whether a `surface_id` param was present at all.
    ///   - text: The text to send.
    /// - Returns: The send resolution.
    func controlSurfaceSendText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        text: String
    ) -> ControlSurfaceSendResolution

    /// Sends a named key for `surface.send_key`. The coordinator selects each
    /// localized error message from ``controlSurfaceInputStrings()``.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, or `nil` for the focused surface.
    ///   - hasSurfaceIDParam: Whether a `surface_id` param was present at all.
    ///   - key: The named key to send.
    /// - Returns: The send resolution.
    func controlSurfaceSendKey(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        key: String
    ) -> ControlSurfaceSendResolution

    // `surface.read_text` has no witness here: it runs on the socket-worker lane
    // (issue #5757) so its full-scrollback formatting stays off the main actor,
    // which the @MainActor coordinator seam cannot host. The app dispatches it
    // directly via `TerminalController.v2SurfaceReadText`.

    // MARK: - resume.set / get / clear

    /// Sets a resume binding for `surface.resume.set`. The app resolves the
    /// target, runs the (possibly blocking, app-bundle-localized) approval flow,
    /// and stores the binding.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors (with the surface-resume precedence).
    ///   - inputs: The pre-parsed resume-set inputs.
    /// - Returns: The resume resolution.
    func controlSurfaceResumeSet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        inputs: ControlSurfaceResumeSetInputs
    ) -> ControlSurfaceResumeResolution

    /// Reads the resume binding for `surface.resume.get`.
    ///
    /// - Parameter routing: The routing selectors (with the surface-resume
    ///   precedence).
    /// - Returns: The resume resolution.
    func controlSurfaceResumeGet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool
    ) -> ControlSurfaceResumeResolution

    /// Clears the resume binding for `surface.resume.clear`, honoring the optional
    /// expected checkpoint/source guards.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors (with the surface-resume precedence).
    ///   - expectedCheckpointID: The optional expected checkpoint guard.
    ///   - expectedSource: The optional expected source guard.
    /// - Returns: The resume resolution.
    func controlSurfaceResumeClear(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        expectedCheckpointID: String?,
        expectedSource: String?
    ) -> ControlSurfaceResumeResolution

    // MARK: - report_tty / report_pwd / report_shell_state / ports_kick

    /// Records a reported TTY name for `surface.report_tty`.
    ///
    /// - Parameters:
    ///   - workspaceID: The target workspace.
    ///   - requestedSurfaceID: The explicit `surface_id`, or `nil` to resolve.
    ///   - ttyName: The reported (trimmed, non-empty) TTY name.
    /// - Returns: The report resolution.
    func controlSurfaceReportTTY(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        ttyName: String
    ) -> ControlSurfaceReportTTYResolution

    /// Records a reported current working directory for `surface.report_pwd`.
    ///
    /// - Parameters:
    ///   - workspaceID: The target workspace.
    ///   - requestedSurfaceID: The explicit `surface_id`, or `nil` to resolve.
    ///   - path: The reported (trimmed, non-empty) current working directory.
    /// - Returns: The report resolution.
    func controlSurfaceReportPWD(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        path: String
    ) -> ControlSurfaceReportPWDResolution

    /// Parses a raw shell-activity token via the app's
    /// `parseReportedShellActivityState`, returning the state's raw value (the
    /// coordinator rejects a `nil` result as `invalid_params`).
    ///
    /// - Parameter rawState: The raw `state`/`shell_state`/`activity` token.
    /// - Returns: The parsed state's raw value, or `nil` when unrecognized.
    ///
    /// `nonisolated` because the app parser is a pure static token table and
    /// the worker-lane v1 `report_shell_state` body validates off the main
    /// actor.
    nonisolated func controlSurfaceParseShellActivityState(_ rawState: String) -> String?

    /// Parses a raw port-scan kick reason via the app's
    /// `parseRemotePortScanKickReason`, returning the reason's raw value (the
    /// coordinator rejects a `nil` result as `invalid_params`).
    ///
    /// - Parameter rawReason: The raw `reason` token.
    /// - Returns: The parsed reason's raw value, or `nil` when unrecognized.
    ///
    /// `nonisolated` because the app parser is a pure static token table and
    /// the worker-lane v1 `ports_kick` body validates off the main actor.
    nonisolated func controlSurfaceParsePortScanKickReason(_ rawReason: String) -> String?

    /// Records reported shell-activity state for `surface.report_shell_state`.
    ///
    /// - Parameters:
    ///   - workspaceID: The target workspace.
    ///   - requestedSurfaceID: The explicit `surface_id`, or `nil` for the
    ///     workspace-wide async path.
    ///   - stateRawValue: The parsed activity state's raw value.
    /// - Returns: The report-shell-state resolution.
    func controlSurfaceReportShellState(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        stateRawValue: String
    ) -> ControlSurfaceReportShellStateResolution

    /// Kicks the port scanner for `surface.ports_kick`.
    ///
    /// - Parameters:
    ///   - workspaceID: The target workspace.
    ///   - requestedSurfaceID: The explicit `surface_id`, or `nil` to resolve.
    ///   - reasonRawValue: The parsed kick reason's raw value.
    /// - Returns: The ports-kick resolution.
    func controlSurfacePortsKick(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        reasonRawValue: String
    ) -> ControlSurfacePortsKickResolution

    // MARK: - debug.terminals

    /// Snapshots the global terminal-surface debug table for `debug.terminals`.
    ///
    /// The payload is dozens of irreducibly app-coupled `NSWindow`/`NSView`/
    /// Ghostty-pointer fields, so the app returns it already shaped as a bridged
    /// ``JSONValue`` object (the documented single-method passthrough exception),
    /// or `nil` when `AppDelegate` is unavailable.
    ///
    /// - Returns: The bridged payload, or `nil` when unavailable.
    func controlDebugTerminals() -> JSONValue?
}
