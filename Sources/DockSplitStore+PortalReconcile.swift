import AppKit

/// Event-driven follow-up state for the Dock portal reconciler.
///
/// Every request performs an immediate pass. Observers remain installed only
/// while a visible portal reports that its AppKit host is not mounted yet; the
/// next real host/registry lifecycle event performs the next pass. There is no
/// timer, backoff, or focus-driven layout dependency.
@MainActor
final class DockPortalReconcileState {
    var observers: [NSObjectProtocol] = []
    var reason: String?
    var isAttempting = false
    var scheduledRequestCount = 0

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

extension DockSplitStore {
    func scheduleDockPortalReconcile(reason: String) {
        let state = dockPortalReconcileState
        state.scheduledRequestCount += 1
        state.reason = reason
        installDockPortalReconcileObservers()
        attemptDockPortalReconcile()
    }

    private func installDockPortalReconcileObservers() {
        let state = dockPortalReconcileState
        guard state.observers.isEmpty else { return }

        let wake: () -> Void = { [weak self] in
            self?.attemptDockPortalReconcile()
        }
        let notificationNames: [Notification.Name] = [
            .terminalSurfaceDidBecomeReady,
            .terminalSurfaceHostedViewDidMoveToWindow,
            .terminalPortalVisibilityDidChange,
            .browserPortalRegistryDidChange,
        ]
        for name in notificationNames {
            state.observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                wake()
            })
        }
    }

    func clearDockPortalReconcile() {
        let state = dockPortalReconcileState
        state.observers.forEach { NotificationCenter.default.removeObserver($0) }
        state.observers.removeAll()
        state.reason = nil
    }

    private func attemptDockPortalReconcile() {
        let state = dockPortalReconcileState
        guard !state.observers.isEmpty, !state.isAttempting else { return }
        state.isAttempting = true
        defer { state.isAttempting = false }

        let reason = state.reason ?? "dock.portal.reconcile"
        if !reconcileDockPortalPass(reason: reason) {
            clearDockPortalReconcile()
        }
    }

    @discardableResult
    func reconcileDockPortalPass(reason: String) -> Bool {
        var needsFollowUpPass = false
        flushDockWindowLayouts()

        withCoalescedTerminalViewReattach {
            for panel in panels.values {
                if panelIsSelectedInVisibleDockPane(panel.id) {
                    needsFollowUpPass = reconcileVisibleDockPortalPanel(panel, reason: reason) || needsFollowUpPass
                } else {
                    applyVisibility(to: panel)
                }
            }
        }

        return needsFollowUpPass
    }

    private func flushDockWindowLayouts() {
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func reconcileVisibleDockPortalPanel(_ panel: any Panel, reason: String) -> Bool {
        if let terminal = panel as? TerminalPanel {
            return reconcileVisibleDockTerminalPortal(terminal)
        }
        if let browser = panel as? BrowserPanel {
            return reconcileVisibleDockBrowserPortal(browser, reason: reason)
        }
        return false
    }

    private func reconcileVisibleDockTerminalPortal(_ terminal: TerminalPanel) -> Bool {
        var needsFollowUpPass = false
        let hostedView = terminal.hostedView
        hostedView.setVisibleInUI(true)
        hostedView.setActive(panelIsActiveInVisibleDockPane(terminal.id))

        let needsPortalReattach = TerminalWindowPortalRegistry
            .updateEntryVisibility(for: hostedView, visibleInUI: true)
        let hasUsableBounds = hostedView.bounds.width > 1 && hostedView.bounds.height > 1
        let hasSurface = terminal.surface.surface != nil
        let isAttached = terminal.surface.isViewInWindow && hostedView.superview != nil

        if needsPortalReattach || !isAttached || !hasUsableBounds || !hasSurface {
            requestTerminalViewReattach(terminal)
            needsFollowUpPass = true
        }

        hostedView.reconcileGeometryNow()
        if terminal.surface.surface != nil {
            terminal.surface.forceRefresh()
        }
        if terminal.surface.surface == nil, isAttached, hasUsableBounds {
            terminal.surface.requestBackgroundSurfaceStartIfNeeded()
            needsFollowUpPass = true
        }

        return needsFollowUpPass
    }

    private func reconcileVisibleDockBrowserPortal(_ browser: BrowserPanel, reason: String) -> Bool {
        browser.noteWebViewVisibility(true, reason: "portal.\(reason)", recordIfUnchanged: true)

        let anchorView = browser.portalAnchorView
        guard dockBrowserPortalAnchorReady(anchorView) else { return true }

        let webView = browser.webView
        let snapshot = BrowserWindowPortalRegistry.debugSnapshot(for: webView)
        if snapshot?.visibleInUI == false {
            BrowserWindowPortalRegistry.updateEntryVisibility(
                for: webView,
                visibleInUI: true,
                zPriority: 1
            )
        }

        let wasReady = dockBrowserPortalReady(browser)
        if !wasReady &&
            (snapshot == nil || !BrowserWindowPortalRegistry.isWebView(webView, boundTo: anchorView)) {
            BrowserWindowPortalRegistry.bind(
                webView: webView,
                to: anchorView,
                visibleInUI: true,
                zPriority: 1
            )
        }

        if !wasReady && !dockBrowserPortalReady(browser) {
            BrowserWindowPortalRegistry.synchronizeForAnchor(anchorView)
        }
        let isReady = dockBrowserPortalReady(browser)
        if isReady && (!wasReady || snapshot?.containerHidden == true) {
            BrowserWindowPortalRegistry.refresh(webView: webView, reason: reason)
        }
        return !isReady
    }

    func dockBrowserPortalAnchorReady(_ anchorView: NSView) -> Bool {
        anchorView.window != nil &&
            anchorView.superview != nil &&
            anchorView.bounds.width > 1 &&
            anchorView.bounds.height > 1
    }

    func dockBrowserPortalReady(_ browser: BrowserPanel) -> Bool {
        dockBrowserPortalAnchorReady(browser.portalAnchorView) &&
            browser.webView.window != nil &&
            browser.webView.superview != nil &&
            BrowserWindowPortalRegistry.isWebView(browser.webView, boundTo: browser.portalAnchorView)
    }

    func dockBrowserPortalNeedsReconcile(_ browser: BrowserPanel) -> Bool {
        let snapshot = BrowserWindowPortalRegistry.debugSnapshot(for: browser.webView)
        return snapshot == nil ||
            snapshot?.visibleInUI == false ||
            snapshot?.containerHidden == true ||
            !dockBrowserPortalReady(browser)
    }
}
