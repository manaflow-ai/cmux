import Foundation
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

    /// Reentrancy latch for ``reconcileFocusState()`` (legacy
    /// `Workspace.isReconcilingFocusState`): the reconcile mutates bonsplit focus
    /// and panel focus, which can feed back into another reconcile; this guards
    /// against re-entering while a reconcile is in flight.
    private var isReconcilingFocusState = false

    /// Coalesce latch for ``scheduleFocusReconcile()`` (legacy
    /// `Workspace.focusReconcileScheduled`): collapses a burst of schedule
    /// requests within one turn into a single deferred reconcile.
    private var focusReconcileScheduled = false

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

    // MARK: - Focus-state reconcile

    /// Converges AppKit first responder and panel focus onto the model source of
    /// truth (the bonsplit focused pane + selected tab). Legacy
    /// `Workspace.reconcileFocusState()`: reentrancy-guarded, inert while portal
    /// rendering is disabled, and falling back to the first registered panel when
    /// no pane resolves to a live panel.
    public func reconcileFocusState() {
        guard let host else { return }
        guard host.panelFocusNavPortalRenderingEnabled else { return }
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = host.panelFocusNavFocusedPaneId,
           let focusedTabId = host.panelFocusNavSelectedTabId(inPane: focusedPane),
           let mappedPanelId = host.panelFocusNavPanelId(fromSurfaceId: focusedTabId),
           host.panelFocusNavPanelExists(panelId: mappedPanelId) {
            targetPanelId = mappedPanelId
        } else {
            for pane in host.panelFocusNavAllPaneIds {
                guard let selectedTabId = host.panelFocusNavSelectedTabId(inPane: pane),
                      let mappedPanelId = host.panelFocusNavPanelId(fromSurfaceId: selectedTabId),
                      host.panelFocusNavPanelExists(panelId: mappedPanelId) else { continue }
                host.panelFocusNavFocusPane(pane)
                host.panelFocusNavSelectTab(selectedTabId)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = host.panelFocusNavAllPanelIds.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = host.panelFocusNavSurfaceId(fromPanelId: fallbackPanelId),
               let fallbackPane = host.panelFocusNavAllPaneIds.first(where: { paneId in
                   host.panelFocusNavTabIds(inPane: paneId).contains(where: { $0 == fallbackTabId })
               }) {
                host.panelFocusNavFocusPane(fallbackPane)
                host.panelFocusNavSelectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, host.panelFocusNavPanelExists(panelId: targetPanelId) else { return }

        host.panelFocusNavUnfocusAllExcept(panelId: targetPanelId)

        host.panelFocusNavFocusPanel(panelId: targetPanelId)
        host.panelFocusNavEnsureTerminalFocus(panelId: targetPanelId)
        host.panelFocusNavApplyFocusedPanelDirectory(panelId: targetPanelId)
        host.panelFocusNavApplyFocusedPanelGitBranch(panelId: targetPanelId)
        host.panelFocusNavApplyFocusedPanelPullRequest(panelId: targetPanelId)
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    /// Legacy `Workspace.scheduleFocusReconcile()`.
    public func scheduleFocusReconcile() {
        guard let host else { return }
        guard host.panelFocusNavPortalRenderingEnabled else { return }
        host.panelFocusNavNoteScheduleDuringDetach()
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        host.panelFocusNavScheduleAfterCurrentTurn { [weak self] in
            guard let self else { return }
            guard let host = self.host else { return }
            guard host.panelFocusNavPortalRenderingEnabled else {
                self.focusReconcileScheduled = false
                return
            }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }
}
