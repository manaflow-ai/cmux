public import Foundation

/// The workspace-side seam ``WorkspaceLayoutFollowUpCoordinator`` drives the
/// live portal show/hide and terminal-geometry reconcile through after a split,
/// tab move, zoom, focus, or portal-rendering change.
///
/// **Why a synchronous read-plus-side-effect protocol and not value snapshots.**
/// Each follow-up attempt is one MainActor turn that flushes pending AppKit
/// layout, then walks the live panel registry and the `TerminalWindowPortal` /
/// `BrowserWindowPortal` registries to show/hide each surface's portal at the
/// current rendered set and reconcile each visible terminal's geometry, exactly
/// as the legacy `Workspace` follow-up bodies did inline. The reconcile primitives
/// observe and mutate the authoritative `BonsplitController` split tree, the
/// per-panel `hostedView`/`webView`, and the portal registries in place; a freshly
/// shown portal's readiness is re-read immediately and the next predicate walks the
/// same live state. Routing these through a synchronous seam preserves every
/// in-turn ordering and the convergence loop's progress accounting; an async
/// value-snapshot design would open suspension windows the legacy code never had,
/// and these reconciles are render-adjacent (they run on layout changes, never per
/// keystroke).
///
/// **What stays here vs. in the coordinator.** The coordinator owns the
/// follow-up *state machine*: the pending reason / focus / browser panel ids, the
/// needs-geometry flag, the attempt version + stall count, the
/// portal-rendering-enabled flag, the pending reparent-suppression set, and the
/// Clock-driven retry/timeout tasks. This host owns the *primitives that hold
/// app-target types*: the panel registry walks (`TerminalPanel`/`BrowserPanel`),
/// the portal registries, `NSApp` layout flushes, AppKit first-responder focus,
/// and the `NotificationCenter` observer install (its `Notification.Name`s are
/// app-target constants). The coordinator never names an app type; it calls these
/// witnesses.
@MainActor
public protocol WorkspaceLayoutFollowUpHosting: AnyObject {
    // MARK: Observer install (host owns the app-target Notification.Names)

    /// Installs the layout-follow-up event observers (the `NSWindow.didUpdate`,
    /// terminal-ready, hosted-view-moved-to-window, terminal/browser
    /// portal-registry-changed, and ghostty/browser first-responder
    /// `NotificationCenter` watches, plus the `paneTree` panels observation), each
    /// invoking `onEvent` on the main actor. Returns a handle whose
    /// ``WorkspaceLayoutFollowUpObservation/cancel()`` removes them all (legacy
    /// `Workspace.installLayoutFollowUpObservers()`). The coordinator owns the
    /// handle's lifetime.
    func beginObservingLayoutFollowUpEvents(
        onEvent: @escaping @MainActor () -> Void
    ) -> WorkspaceLayoutFollowUpObservation

    // MARK: Geometry / portal reconcile primitives

    /// Flushes pending AppKit layout for every visible window so terminal-host
    /// bounds reflect the latest split topology (legacy
    /// `Workspace.flushWorkspaceWindowLayouts()`).
    func layoutFollowUpFlushWindowLayouts()

    /// Reconciles remaining terminal-view geometries after a split topology
    /// change, returning true when another pass is needed (legacy
    /// `Workspace.reconcileTerminalGeometryPass()`).
    func layoutFollowUpReconcileTerminalGeometryPass() -> Bool

    /// Shows/hides each terminal portal at the current rendered layout (legacy
    /// `Workspace.reconcileTerminalPortalVisibilityForCurrentRenderedLayout()`).
    func layoutFollowUpReconcileTerminalPortalVisibility()

    /// Whether any terminal portal's visibility still diverges from the rendered
    /// layout (legacy `Workspace.terminalPortalVisibilityNeedsFollowUp()`).
    func layoutFollowUpTerminalPortalVisibilityNeedsFollowUp() -> Bool

    /// Shows/hides/refreshes each browser portal at the current rendered layout
    /// (legacy
    /// `Workspace.reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason:)`).
    func layoutFollowUpReconcileBrowserPortalVisibility(reason: String)

    /// Whether any browser portal's visibility/binding still diverges from the
    /// rendered layout (legacy `Workspace.browserPortalVisibilityNeedsFollowUp()`).
    func layoutFollowUpBrowserPortalVisibilityNeedsFollowUp() -> Bool

    // MARK: Pending terminal-focus follow-up

    /// Re-asserts AppKit first responder for the pending terminal-focus panel and
    /// returns whether the focus target is now settled (true clears the pending
    /// id). Returns true when the panel no longer exists. Lifted from the
    /// terminal-focus block of `Workspace.attemptEventDrivenLayoutFollowUp()`.
    func layoutFollowUpEnsureTerminalFocus(panelId: UUID) -> Bool

    /// Whether the pending terminal-focus panel still needs a follow-up
    /// (not focused, or its surface view is not first responder). Returns false
    /// when there is no such panel (legacy `Workspace.terminalFocusNeedsFollowUp()`
    /// over the coordinator's pending id).
    func layoutFollowUpTerminalFocusNeedsFollowUp(panelId: UUID) -> Bool

    // MARK: Pending browser-panel readiness follow-up

    /// Synchronizes/refreshes the pending browser panel's portal binding and
    /// returns whether it is now ready (true clears the pending id). Returns true
    /// when the panel no longer exists. `reason` is the active follow-up reason
    /// (the legacy `layoutFollowUpReason ?? "workspace.layout"`) passed to the
    /// portal refresh. Lifted from the browser-panel block of
    /// `Workspace.attemptEventDrivenLayoutFollowUp()`.
    func layoutFollowUpReconcilePendingBrowserPanel(panelId: UUID, reason: String) -> Bool

    /// Whether the pending browser panel still needs a follow-up (its portal is
    /// not ready). Returns false when there is no such panel (legacy
    /// `Workspace.browserPanelNeedsFollowUp()` over the coordinator's pending id).
    func layoutFollowUpBrowserPanelNeedsFollowUp(panelId: UUID) -> Bool

    // MARK: Pending browser split-zoom-exit focus follow-up

    /// Re-focuses the pending browser split-zoom-exit panel when its selection /
    /// anchor has not converged, returning whether the pending id should be
    /// retained for another pass (false clears it). Lifted from the
    /// browser-exit-focus block of `Workspace.attemptEventDrivenLayoutFollowUp()`.
    func layoutFollowUpReconcileBrowserExitFocus(panelId: UUID) -> Bool

    // MARK: Moved-terminal refresh

    /// Forces an `NSViewRepresentable` reattach for a terminal panel after a
    /// drag/move reparent, keeping portal host binding current when a pane
    /// auto-closes during tab moves (legacy
    /// `terminalPanel(for:)?.requestViewReattach()` at the head of
    /// `Workspace.scheduleMovedTerminalRefresh`). No-op when the panel is not a
    /// terminal.
    func layoutFollowUpRequestMovedTerminalReattach(panelId: UUID)

    /// Runs one post-move geometry/surface refresh pass for a terminal panel
    /// (legacy `runRefreshPass` body inside `Workspace.scheduleMovedTerminalRefresh`).
    /// No-op when the panel is not a terminal.
    func layoutFollowUpRefreshMovedTerminal(panelId: UUID)

    /// Whether the panel is still a terminal panel, gating the moved-terminal
    /// refresh (legacy `guard terminalPanel(for: panelId) != nil`).
    func layoutFollowUpIsTerminalPanel(panelId: UUID) -> Bool

    // MARK: Portal-rendering teardown

    /// Hides all terminal and browser portals for this workspace (legacy
    /// `Workspace.hideAllTerminalPortalViews()` + `hideAllBrowserPortalViews()`),
    /// called when portal rendering is disabled or a follow-up runs while disabled.
    func layoutFollowUpHideAllPortals()
}
