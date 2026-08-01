public import Foundation

/// The pane-domain slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella).
///
/// The app target (today `TerminalController`, the interim composition owner)
/// conforms by reading live `TabManager` / `Workspace` / `BonsplitController`
/// state and the Ghostty surfaces. Every method is `@MainActor` because its
/// conformer and the coordinator both live on the main actor, so these are plain
/// in-isolation calls — the per-read `v2MainSync` hops the legacy command bodies
/// used disappear once the domain moves onto the coordinator.
///
/// No app types cross the seam: reads return `Control*` snapshot values and
/// mutations take pre-parsed selectors/ids and return small Sendable resolution
/// enums. The legacy `v2LocatePane` stays app-side (it returns `TabManager` /
/// `Workspace` / `PaneID`); the conformance calls it internally.
@MainActor
public protocol ControlPaneContext: AnyObject {
    /// Snapshots the resolved workspace's pane layout for `pane.list`.
    ///
    /// - Parameter routing: The routing selectors for TabManager + workspace
    ///   resolution (legacy `v2ResolveTabManager` / `v2ResolveWorkspace`).
    /// - Returns: The pane-list snapshot, or `nil` when no TabManager or
    ///   workspace resolves (the coordinator maps each to its legacy error).
    func controlPaneList(routing: ControlRoutingSelectors) -> ControlPaneListSnapshot?

    /// Whether a TabManager resolves for `pane.list` / similar routing, used to
    /// distinguish the `unavailable` failure from the `not_found` failure.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: Whether a TabManager resolved.
    func controlPaneRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool

    /// Returns the app-localized message for malformed `pane.resize` parameters.
    ///
    /// - Returns: The localized invalid-parameters message.
    func controlPaneResizeInvalidParametersMessage() -> String

    /// Focuses the pane `paneID` in the resolved workspace for `pane.focus`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - paneID: The pane to focus.
    /// - Returns: The focus resolution.
    func controlPaneFocus(
        routing: ControlRoutingSelectors,
        paneID: UUID
    ) -> ControlPaneFocusResolution

    /// Snapshots one pane's surfaces for `pane.surfaces`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - paneID: The explicit `pane_id`, or `nil` to use the focused pane.
    /// - Returns: The surfaces snapshot, or `nil` when no TabManager, workspace,
    ///   or pane resolves.
    func controlPaneSurfaces(
        routing: ControlRoutingSelectors,
        paneID: UUID?
    ) -> ControlPaneSurfacesSnapshot?

    /// Creates a split pane for `pane.create`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - inputs: The pre-parsed create inputs.
    /// - Returns: The create resolution.
    func controlPaneCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution

    /// Resizes a pane for `pane.resize`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - inputs: The pre-parsed (and pre-validated) resize inputs.
    /// - Returns: The resize resolution.
    func controlPaneResize(
        routing: ControlRoutingSelectors,
        inputs: ControlPaneResizeInputs
    ) -> ControlPaneResizeResolution

    /// Swaps two panes within a workspace for `pane.swap`.
    ///
    /// - Parameters:
    ///   - sourcePaneID: The source pane (located across windows via the legacy
    ///     `v2LocatePane`).
    ///   - targetPaneID: The target pane (must be in the source workspace).
    ///   - requestedFocus: Whether the request asked to focus the target pane
    ///     (the seam applies the socket focus-allowance gate).
    /// - Returns: The swap resolution.
    func controlPaneSwap(
        sourcePaneID: UUID,
        targetPaneID: UUID,
        requestedFocus: Bool
    ) -> ControlPaneSwapResolution

    /// Breaks a surface out into a new workspace for `pane.break`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - paneID: The explicit source `pane_id`, or `nil` for the focused pane.
    ///   - surfaceID: The explicit `surface_id`, or `nil` to derive it from the
    ///     source pane's selected surface (then the workspace's focused panel).
    ///   - requestedFocus: Whether to select the new workspace (the seam applies
    ///     the socket focus-allowance gate).
    /// - Returns: The break resolution.
    func controlPaneBreak(
        routing: ControlRoutingSelectors,
        paneID: UUID?,
        surfaceID: UUID?,
        requestedFocus: Bool
    ) -> ControlPaneBreakResolution

    /// Joins a surface into a target pane for `pane.join`, delegating to the
    /// shared surface-move logic.
    ///
    /// - Parameters:
    ///   - targetPaneID: The destination pane.
    ///   - surfaceID: The explicit `surface_id` to move, or `nil` to derive it
    ///     from `sourcePaneID`'s selected surface.
    ///   - sourcePaneID: The source `pane_id`, used only when `surfaceID` is
    ///     `nil`.
    ///   - hasFocusParam: Whether the request carried a `focus` param (forwarded
    ///     to the surface-move call only when present, as the legacy body did).
    ///   - focus: The `focus` param value (used only when `hasFocusParam`).
    /// - Returns: The join resolution.
    func controlPaneJoin(
        targetPaneID: UUID,
        surfaceID: UUID?,
        sourcePaneID: UUID?,
        hasFocusParam: Bool,
        focus: Bool
    ) -> ControlPaneJoinResolution

    /// Focuses the alternate pane for `pane.last`.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: The last-pane resolution.
    func controlPaneLast(routing: ControlRoutingSelectors) -> ControlPaneLastResolution
}
