public import Bonsplit

/// Orchestrates pane/surface focus navigation for a workspace: Cmd-arrow
/// move-focus across split panes, and next/previous/index/last surface selection
/// within the focused pane.
///
/// Faithful lift of the `Workspace` bonsplit-navigation methods
/// (`moveFocus(direction:)`, `selectNextSurface`, `selectPreviousSurface`,
/// `selectSurface(at:)`, `selectLastSurface`): the canvas-vs-splits branch, the
/// unfocus-previous-then-navigate ordering, and the read-mutate-reconcile shape
/// (read the focused pane's selected tab after a focus/tab mutation and run
/// `applyTabSelection` to align AppKit first responder). The primitives that
/// touch app-target types (the `BonsplitController`, the `any Panel` registry's
/// `unfocus()`, the `applyTabSelection` chain, the canvas model) stay app-side
/// behind ``PanelFocusNavigationHosting``; this coordinator never names one.
///
/// **Isolation design.** `@MainActor`, not an actor. Every entry point already
/// ran on the main actor: these methods are invoked from keyboard shortcuts, the
/// command palette, and the CLI, and they read and mutate AppKit/bonsplit state
/// synchronously within one turn. Co-locating this orchestration with its callers
/// turns every bridge into a plain call; an actor here would manufacture an
/// isolation domain the design immediately re-enters. The host is held weakly:
/// `Workspace` owns this coordinator, so a strong back-reference would be a
/// retain cycle.
@MainActor
public final class PanelFocusNavigationCoordinator {
    private weak var host: (any PanelFocusNavigationHosting)?

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    public init() {}

    /// Wires the app-side host the navigation drives through. Held weakly.
    public func attach(host: any PanelFocusNavigationHosting) {
        self.host = host
    }

    // MARK: - Pane focus

    /// Moves keyboard focus to the adjacent pane in `direction`, unfocusing the
    /// previously focused panel first and reconciling tab selection after. Legacy
    /// `Workspace.moveFocus(direction:)`.
    public func moveFocus(direction: NavigationDirection) {
        guard let host else { return }
        if host.panelFocusNavIsCanvasLayout {
            host.panelFocusNavMoveCanvasFocus(direction: direction)
            return
        }
        let previousFocusedPanelId = host.panelFocusNavFocusedPanelId

        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = previousFocusedPanelId {
            host.panelFocusNavUnfocusPanel(panelId: prevPanelId)
        }

        host.panelFocusNavNavigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        reconcileFocusedPaneSelection(host: host)
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane. Legacy
    /// `Workspace.selectNextSurface()`.
    public func selectNextSurface() {
        guard let host else { return }
        if host.panelFocusNavIsCanvasLayout, host.panelFocusNavSelectAdjacentCanvasTab(offset: 1) { return }
        host.panelFocusNavSelectNextTab()
        reconcileFocusedPaneSelection(host: host)
    }

    /// Select the previous surface in the currently focused pane. Legacy
    /// `Workspace.selectPreviousSurface()`.
    public func selectPreviousSurface() {
        guard let host else { return }
        if host.panelFocusNavIsCanvasLayout, host.panelFocusNavSelectAdjacentCanvasTab(offset: -1) { return }
        host.panelFocusNavSelectPreviousTab()
        reconcileFocusedPaneSelection(host: host)
    }

    /// Select a surface by index in the currently focused pane. Legacy
    /// `Workspace.selectSurface(at:)`.
    public func selectSurface(at index: Int) {
        guard let host else { return }
        guard let focusedPaneId = host.panelFocusNavFocusedPaneId else { return }
        let tabIds = host.panelFocusNavTabIds(inPane: focusedPaneId)
        guard index >= 0 && index < tabIds.count else { return }
        host.panelFocusNavSelectTab(tabIds[index])

        if let tabId = host.panelFocusNavSelectedTabId(inPane: focusedPaneId) {
            host.panelFocusNavApplyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane. Legacy
    /// `Workspace.selectLastSurface()`.
    public func selectLastSurface() {
        guard let host else { return }
        guard let focusedPaneId = host.panelFocusNavFocusedPaneId else { return }
        let tabIds = host.panelFocusNavTabIds(inPane: focusedPaneId)
        guard let last = tabIds.last else { return }
        host.panelFocusNavSelectTab(last)

        if let tabId = host.panelFocusNavSelectedTabId(inPane: focusedPaneId) {
            host.panelFocusNavApplyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    // MARK: - Reconcile

    /// Re-reads the focused pane's selected tab and runs the `applyTabSelection`
    /// chain, the shared tail of `moveFocus`/`selectNextSurface`/
    /// `selectPreviousSurface` (each of which re-reads `focusedPaneId` after the
    /// mutation rather than reusing a captured id).
    private func reconcileFocusedPaneSelection(host: any PanelFocusNavigationHosting) {
        if let paneId = host.panelFocusNavFocusedPaneId,
           let tabId = host.panelFocusNavSelectedTabId(inPane: paneId) {
            host.panelFocusNavApplyTabSelection(tabId: tabId, inPane: paneId)
        }
    }
}
