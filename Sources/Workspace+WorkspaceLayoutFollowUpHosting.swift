import AppKit
import CmuxWorkspaces
import Foundation

/// `Workspace` is the live host for its ``WorkspaceLayoutFollowUpCoordinator``.
/// Each witness reproduces the reads and side effects the legacy `Workspace`
/// follow-up bodies performed inline against the panel registry, the
/// `BonsplitController` split tree, and the `TerminalWindowPortal` /
/// `BrowserWindowPortal` registries. The coordinator owns the follow-up state
/// machine and the Clock-driven retry/timeout; these witnesses are the
/// app-target-typed primitives it drives (portal show/hide, geometry reconcile,
/// AppKit focus, the `NotificationCenter` observer install whose names are
/// app-target constants). The coordinator references this host weakly, so there
/// is no retain cycle.
extension Workspace: WorkspaceLayoutFollowUpHosting {
    // MARK: Observer install

    func beginObservingLayoutFollowUpEvents(
        onEvent: @escaping @MainActor () -> Void
    ) -> WorkspaceLayoutFollowUpObservation {
        // The follow-up event names are app-target `Notification.Name` constants
        // scattered across TabManager/TerminalController/CmuxTerminal, so the
        // literal `addObserver` calls stay here; the coordinator owns only the
        // returned handle's lifetime. Each observer is registered on `.main` and
        // calls `onEvent()` directly, exactly as the legacy
        // `installLayoutFollowUpObservers()` enqueued its attempt.
        var observers: [NSObjectProtocol] = []

        let names: [Notification.Name] = [
            NSWindow.didUpdateNotification,
            .terminalSurfaceDidBecomeReady,
            .terminalSurfaceHostedViewDidMoveToWindow,
            .terminalPortalVisibilityDidChange,
            .browserPortalRegistryDidChange,
            .ghosttyDidBecomeFirstResponderSurface,
            .browserDidBecomeFirstResponderWebView,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                onEvent()
            })
        }

        // `@Observable` replacement for the legacy `panelsPublisher` subscriber;
        // `fireImmediately` reproduces `CurrentValueSubject.sink`'s
        // replay-on-subscribe.
        let panelsObservation = paneTree.observePanels(fireImmediately: true) {
            onEvent()
        }

        return WorkspaceLayoutFollowUpObservation {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            panelsObservation.cancel()
        }
    }

    // MARK: Geometry / portal reconcile primitives

    func layoutFollowUpFlushWindowLayouts() {
        flushWorkspaceWindowLayouts()
    }

    func layoutFollowUpReconcileTerminalGeometryPass() -> Bool {
        reconcileTerminalGeometryPass()
    }

    func layoutFollowUpReconcileTerminalPortalVisibility() {
        _ = reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
    }

    func layoutFollowUpTerminalPortalVisibilityNeedsFollowUp() -> Bool {
        terminalPortalVisibilityNeedsFollowUp()
    }

    func layoutFollowUpReconcileBrowserPortalVisibility(reason: String) {
        _ = reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: reason)
    }

    func layoutFollowUpBrowserPortalVisibilityNeedsFollowUp() -> Bool {
        browserPortalVisibilityNeedsFollowUp()
    }

    // MARK: Pending terminal-focus follow-up

    func layoutFollowUpEnsureTerminalFocus(panelId: UUID) -> Bool {
        // Returns true when the focus target is settled (clear the pending id) or
        // the panel no longer exists. Lifted from the terminal-focus block of the
        // legacy `attemptEventDrivenLayoutFollowUp`.
        if let terminalPanel = terminalPanel(for: panelId),
           focusedPanelId == panelId {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: panelId)
            return terminalPanel.hostedView.isSurfaceViewFirstResponder()
        } else if terminalPanel(for: panelId) == nil {
            return true
        }
        return false
    }

    func layoutFollowUpTerminalFocusNeedsFollowUp(panelId: UUID) -> Bool {
        guard let terminalPanel = terminalPanel(for: panelId) else { return false }
        return focusedPanelId != panelId || !terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    // MARK: Pending browser-panel readiness follow-up

    func layoutFollowUpReconcilePendingBrowserPanel(panelId: UUID, reason: String) -> Bool {
        // Returns true when the panel is ready (clear the pending id) or no longer
        // exists. Lifted from the browser-panel block of the legacy
        // `attemptEventDrivenLayoutFollowUp`.
        guard let browserPanel = browserPanel(for: panelId) else { return true }
        let anchorReady = browserPortalAnchorReady(for: browserPanel)
        let wasReady = browserPortalReady(for: browserPanel)
        if anchorReady && !wasReady {
            BrowserWindowPortalRegistry.synchronizeForAnchor(browserPanel.portalAnchorView)
        }
        let isReady = browserPortalReady(for: browserPanel)
        if isReady,
           (!wasReady || BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)?.containerHidden == true) {
            BrowserWindowPortalRegistry.refresh(
                webView: browserPanel.webView,
                reason: reason
            )
        }
        return isReady
    }

    func layoutFollowUpBrowserPanelNeedsFollowUp(panelId: UUID) -> Bool {
        guard let browserPanel = browserPanel(for: panelId) else { return false }
        return !browserPortalReady(for: browserPanel)
    }

    // MARK: Pending browser split-zoom-exit focus follow-up

    func layoutFollowUpReconcileBrowserExitFocus(panelId: UUID) -> Bool {
        // Returns whether the pending id should be retained (true) for another
        // pass. Lifted from the browser-exit-focus block of the legacy
        // `attemptEventDrivenLayoutFollowUp`: focus + reconcile and retain when the
        // selection/anchor has not converged and the panel still exists.
        guard browserSplitZoomExitFocusNeedsFollowUp(panelId: panelId) else { return false }
        guard browserPanel(for: panelId) != nil else { return false }
        focusPanel(panelId)
        scheduleFocusReconcile()
        return true
    }

    // MARK: Moved-terminal refresh

    func layoutFollowUpRequestMovedTerminalReattach(panelId: UUID) {
        terminalPanel(for: panelId)?.requestViewReattach()
    }

    func layoutFollowUpRefreshMovedTerminal(panelId: UUID) {
        guard let panel = terminalPanel(for: panelId) else { return }
        panel.hostedView.reconcileGeometryNow()
        if panel.surface.surface != nil {
            panel.surface.forceRefresh()
        }
        if panel.surface.surface == nil {
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
        }
    }

    func layoutFollowUpIsTerminalPanel(panelId: UUID) -> Bool {
        terminalPanel(for: panelId) != nil
    }

    // MARK: Portal-rendering teardown

    func layoutFollowUpHideAllPortals() {
        hideAllTerminalPortalViews()
        hideAllBrowserPortalViews()
    }
}
