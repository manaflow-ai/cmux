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

    /// Locates the source surface for `surface.move`: the moved surface, its
    /// source workspace, current pane/index, and default destination pane.
    ///
    /// Preserves the legacy `AppDelegate`-unavailable vs surface-not-found split
    /// (the coordinator maps each to the identical error).
    ///
    /// - Parameter surfaceID: The surface being moved.
    /// - Returns: The source resolution.
    func controlSurfaceMoveLocateSource(surfaceID: UUID) -> ControlSurfaceMoveSourceResolution

    /// Locates the anchor surface for the `.anchor` routing branch of
    /// `surface.move` (`before_surface_id` / `after_surface_id`).
    ///
    /// - Parameter surfaceID: The anchor surface id.
    /// - Returns: The anchor snapshot, or `nil` when the anchor surface, its
    ///   workspace, pane, or index did not resolve (legacy "Anchor surface not
    ///   found").
    func controlSurfaceMoveLocateAnchor(surfaceID: UUID) -> ControlSurfaceMoveAnchorSnapshot?

    /// Locates the pane for the `.pane` routing branch of `surface.move`
    /// (`pane_id`).
    ///
    /// - Parameter paneID: The requested destination pane id.
    /// - Returns: The pane snapshot, or `nil` when the pane did not resolve
    ///   (legacy "Pane not found").
    func controlSurfaceMoveLocatePane(paneID: UUID) -> ControlSurfaceMovePaneSnapshot?

    /// Locates the workspace for the `.workspace` routing branch of
    /// `surface.move` (`workspace_id`).
    ///
    /// - Parameter workspaceID: The requested destination workspace id.
    /// - Returns: The workspace snapshot, or `nil` when the workspace did not
    ///   resolve (legacy "Workspace not found").
    func controlSurfaceMoveLocateWorkspace(workspaceID: UUID) -> ControlSurfaceMoveWorkspaceSnapshot?

    /// Locates the window for the `.window` routing branch of `surface.move`
    /// (`window_id`), preserving the window-not-found vs no-selected-workspace
    /// split.
    ///
    /// - Parameter windowID: The requested destination window id.
    /// - Returns: The window resolution.
    func controlSurfaceMoveLocateWindow(windowID: UUID) -> ControlSurfaceMoveWindowResolution

    /// Performs the same-workspace in-place pane move for `surface.move`
    /// (`Workspace.moveSurface`).
    ///
    /// The app resolves the requested-vs-allowed focus
    /// (`v2FocusAllowed(requested:)`) itself.
    ///
    /// - Parameters:
    ///   - workspaceID: The (shared source/target) workspace.
    ///   - surfaceID: The surface being moved.
    ///   - destinationPaneID: The destination pane.
    ///   - index: The destination index, or `nil`.
    ///   - requestedFocus: Whether the request asked to focus the surface.
    /// - Returns: Whether the move succeeded (legacy `internal_error` / "Failed
    ///   to move surface" on `false`).
    func controlSurfaceMovePerformMove(
        workspaceID: UUID,
        surfaceID: UUID,
        destinationPaneID: UUID,
        index: Int?,
        requestedFocus: Bool
    ) -> Bool

    /// Performs the cross-workspace transfer for `surface.move`: detach from the
    /// source workspace, attach onto the target (rolling back to the source
    /// pane/index on attach failure), then focus the target when allowed.
    ///
    /// The app resolves the requested-vs-allowed focus
    /// (`v2FocusAllowed(requested:)`) itself and drives
    /// `setActiveTabManager` / `selectWorkspace` / `focusMainWindow`.
    ///
    /// - Parameters:
    ///   - sourceWorkspaceID: The workspace the surface currently lives in.
    ///   - sourcePaneID: The surface's current pane (for rollback), or `nil`.
    ///   - sourceIndex: The surface's current index (for rollback), or `nil`.
    ///   - targetWorkspaceID: The destination workspace.
    ///   - targetWindowID: The destination window (focused on success).
    ///   - surfaceID: The surface being moved.
    ///   - destinationPaneID: The destination pane.
    ///   - index: The destination index, or `nil`.
    ///   - requestedFocus: Whether the request asked to focus the surface.
    /// - Returns: The transfer outcome.
    func controlSurfaceMovePerformTransfer(
        sourceWorkspaceID: UUID,
        sourcePaneID: UUID?,
        sourceIndex: Int?,
        targetWorkspaceID: UUID,
        targetWindowID: UUID,
        surfaceID: UUID,
        destinationPaneID: UUID,
        index: Int?,
        requestedFocus: Bool
    ) -> ControlSurfaceMoveTransferOutcome

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

    /// Parses a raw shell-activity token via
    /// `PanelShellActivityState.parseReported`, returning the state's raw value
    /// (the coordinator rejects a `nil` result as `invalid_params`).
    ///
    /// - Parameter rawState: The raw `state`/`shell_state`/`activity` token.
    /// - Returns: The parsed state's raw value, or `nil` when unrecognized.
    ///
    /// `nonisolated` because the app parser is a pure static token table and
    /// the worker-lane v1 `report_shell_state` body validates off the main
    /// actor.
    nonisolated func controlSurfaceParseShellActivityState(_ rawState: String) -> String?

    /// Parses a raw port-scan kick reason via
    /// `PortScanKickReason.parseReported`, returning the reason's raw value (the
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

    // MARK: - v1 line-protocol surface/input bodies

    /// The v1 `list_surfaces` body: lists the ordered panels of the resolved
    /// workspace (current when `tabArg` is empty), marking the focused one.
    ///
    /// The whole raw reply line is returned verbatim — byte-identical to the
    /// legacy `TerminalController.listSurfaces`. The witness carries the
    /// irreducibly app-coupled body (`TabManager` / `Workspace` ordered-panel
    /// reads behind the legacy `v2MainSync` hop).
    ///
    /// - Parameter tabArg: The raw workspace selector argument (id or index),
    ///   or empty for the current workspace.
    /// - Returns: The raw v1 reply line.
    func controlSurfaceListV1(tabArg: String) -> String

    /// The v1 `focus_surface` body: focuses a panel of the selected workspace by
    /// UUID or 0-based index. Returns the raw v1 reply verbatim (legacy
    /// `focusSurface`).
    ///
    /// - Parameter arg: The raw panel selector argument.
    /// - Returns: The raw v1 reply line.
    func controlSurfaceFocusV1(arg: String) -> String

    /// The v1 `send` body: sends (escape-unescaped) text to the focused terminal
    /// of the selected workspace. Returns the raw v1 reply verbatim (legacy
    /// `sendInput`).
    ///
    /// - Parameter text: The raw text argument.
    /// - Returns: The raw v1 reply line.
    func controlSurfaceSendInputV1(text: String) -> String

    /// The v1 `send_key` body: sends a named key to the focused terminal of the
    /// selected workspace. Returns the raw v1 reply verbatim (legacy `sendKey`).
    ///
    /// - Parameter keyName: The raw key-name argument.
    /// - Returns: The raw v1 reply line.
    func controlSurfaceSendKeyV1(keyName: String) -> String

    /// The v1 `send_surface` body: sends (escape-unescaped) text to a specific
    /// terminal by id or index. Returns the raw v1 reply verbatim (legacy
    /// `sendInputToSurface`).
    ///
    /// - Parameter args: The raw `<id|idx> <text>` argument remainder.
    /// - Returns: The raw v1 reply line.
    func controlSurfaceSendInputToSurfaceV1(args: String) -> String

    /// The v1 `send_key_surface` body: sends a named key to a specific terminal
    /// by id or index. Returns the raw v1 reply verbatim (legacy
    /// `sendKeyToSurface`).
    ///
    /// - Parameter args: The raw `<id|idx> <key>` argument remainder.
    /// - Returns: The raw v1 reply line.
    func controlSurfaceSendKeyToSurfaceV1(args: String) -> String

    #if DEBUG
    /// The DEBUG-only v1 `send_workspace` body: sends (escape-unescaped) text to
    /// the selected terminal of an arbitrary workspace by UUID. Returns the raw
    /// v1 reply verbatim (legacy `sendInputToWorkspace`).
    ///
    /// - Parameter args: The raw `<workspace_id> <text>` argument remainder.
    /// - Returns: The raw v1 reply line.
    func controlSurfaceSendInputToWorkspaceV1(args: String) -> String
    #endif

    /// The v1 `read_screen` body: reads plain-text terminal contents for the
    /// resolved surface (with optional scrollback / line-limit options). Returns
    /// the raw v1 reply verbatim (legacy `readScreenText`).
    ///
    /// - Parameter args: The raw `[id|idx] [--scrollback] [--lines N]` argument
    ///   remainder.
    /// - Returns: The decoded plain-text screen contents, or an `ERROR:` line.
    func controlSurfaceReadScreenV1(args: String) -> String
}
