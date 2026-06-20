public import Foundation

/// The live-app seam for the worker-lane `debug.sidebar.simulate_drag` control
/// command, read by ``ControlSidebarSimulateDragWorker``.
///
/// Param resolution and every `SidebarDragState` mutation live app-side because
/// they reach types the control package must not import (`AppDelegate`, the
/// per-window `TabManager`, and the `CmuxSidebar` `SidebarDragState` /
/// `SidebarDropIndicator`). The seam inverts that: the package owns the protocol
/// and the worker-lane orchestration; the app conforms and performs each
/// main-actor side effect.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: this command runs on the nonisolated
/// socket-worker lane (it is a `#if DEBUG` profiling driver whose inter-tick
/// `Thread.sleep` must never block the main actor). Every member is synchronous
/// and hops to the main actor inside the conformer (the legacy body's `v2MainSync`
/// blocks), so the worker calls them directly from the worker thread, exactly as
/// the legacy `nonisolated` body did. Each call is one main hop, matching the
/// legacy one-`v2MainSync`-per-side-effect cadence.
#if DEBUG
public protocol ControlSidebarSimulateDragReading: Sendable {
    /// Resolves and validates one request (the legacy plan `v2MainSync` block):
    /// window-id / tab-id ref resolution, the per-window `TabManager` lookup, the
    /// mounted-sidebar guard, the from/to index lookup, and the `duration_ms` /
    /// `steps` defaults.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: A runnable plan, or the legacy typed error.
    func plan(params: [String: JSONValue]) -> ControlSidebarSimulateDragPlanOutcome

    /// Begins the simulated drag (the legacy `startedOK` `v2MainSync` block):
    /// marks the drag simulator-driven so the failsafe monitor is skipped, then
    /// calls `beginDragging(tabId:)`.
    ///
    /// - Parameters:
    ///   - windowId: The target window's id.
    ///   - fromTabId: The dragged tab's id.
    /// - Returns: `false` when the sidebar unregistered before the drag could
    ///   start (the legacy `not_found` failure), `true` once begun.
    func begin(windowId: UUID, fromTabId: UUID) -> Bool

    /// Applies one drop-indicator tick (the legacy per-step `v2MainSync` block):
    /// sets the drop indicator on the resolved target tab.
    ///
    /// - Parameters:
    ///   - windowId: The target window's id.
    ///   - tabId: The tab the indicator points at this tick.
    ///   - edgeIsBottom: Whether the indicator's edge is the bottom edge (the
    ///     legacy `edge == .bottom`; `false` is the top edge).
    /// - Returns: `false` when the sidebar unregistered mid-simulation (the legacy
    ///   `aborted` path), `true` once applied.
    func tick(windowId: UUID, tabId: UUID, edgeIsBottom: Bool) -> Bool

    /// Clears the simulated drag (the legacy final `v2MainSync` block):
    /// `clearDrag()` then resets the simulator-driven flag. A no-op when the
    /// sidebar already unregistered.
    ///
    /// - Parameter windowId: The target window's id.
    func clear(windowId: UUID)
}
#endif
