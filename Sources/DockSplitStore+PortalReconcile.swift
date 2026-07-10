import AppKit

/// Event-driven follow-up state for the Dock portal reconciler, owned by
/// `DockSplitStore.dockPortalReconcileState`. Mirrors the state backing
/// `Workspace.beginEventDrivenLayoutFollowUp`.
@MainActor
final class DockPortalReconcileState {
    var observers: [NSObjectProtocol] = []
    var timeoutWorkItem: DispatchWorkItem?
    var reason: String?
    var attemptScheduled = false
    var attemptVersion = 0
    var stalledAttemptCount = 0
    var isAttempting = false
    var scheduledRequestCount = 0

    deinit {
        timeoutWorkItem?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

extension DockSplitStore {
    private static let dockPortalReconcileTimeout: TimeInterval = 2

    func scheduleDockPortalReconcile(reason: String) {
        let state = dockPortalReconcileState
        state.scheduledRequestCount += 1
        state.reason = reason
        state.stalledAttemptCount = 0
        state.attemptVersion &+= 1
        state.attemptScheduled = false

        if state.timeoutWorkItem == nil {
            installDockPortalReconcileObservers()
        }
        refreshDockPortalReconcileTimeout()
        scheduleDockPortalReconcileAttempt()
    }

    private func installDockPortalReconcileObservers() {
        let state = dockPortalReconcileState
        guard state.timeoutWorkItem == nil else { return }

        let wake: () -> Void = { [weak self] in
            self?.wakeDockPortalReconcileForStructuralEvent()
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

    private func refreshDockPortalReconcileTimeout() {
        let state = dockPortalReconcileState
        state.timeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearDockPortalReconcile()
        }
        state.timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.dockPortalReconcileTimeout,
            execute: workItem
        )
    }

    func clearDockPortalReconcile() {
        let state = dockPortalReconcileState
        state.timeoutWorkItem?.cancel()
        state.timeoutWorkItem = nil
        state.observers.forEach { NotificationCenter.default.removeObserver($0) }
        state.observers.removeAll()
        state.reason = nil
        state.attemptVersion &+= 1
        state.attemptScheduled = false
        state.stalledAttemptCount = 0
    }

    private func wakeDockPortalReconcileForStructuralEvent() {
        let state = dockPortalReconcileState
        guard state.timeoutWorkItem != nil else { return }
        state.stalledAttemptCount = 0
        state.attemptVersion &+= 1
        state.attemptScheduled = false
        scheduleDockPortalReconcileAttempt()
    }

    private func scheduleDockPortalReconcileAttempt() {
        let state = dockPortalReconcileState
        guard state.timeoutWorkItem != nil else { return }
        guard !state.attemptScheduled else { return }

        state.attemptScheduled = true
        let delay = dockPortalReconcileBackoffDelay()
        let version = state.attemptVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let state = self.dockPortalReconcileState
            guard state.attemptVersion == version,
                  state.timeoutWorkItem != nil else { return }
            state.attemptScheduled = false
            self.attemptDockPortalReconcile()
        }
    }

    private func dockPortalReconcileBackoffDelay() -> TimeInterval {
        let stalledAttemptCount = dockPortalReconcileState.stalledAttemptCount
        guard stalledAttemptCount > 0 else { return 0 }
        let baseDelay: TimeInterval = 0.01
        let exponent = min(stalledAttemptCount - 1, 5)
        return min(0.25, baseDelay * pow(2, Double(exponent)))
    }

    private func attemptDockPortalReconcile() {
        let state = dockPortalReconcileState
        guard state.timeoutWorkItem != nil, !state.isAttempting else { return }
        state.isAttempting = true
        defer { state.isAttempting = false }

        let attemptVersion = state.attemptVersion
        let reason = state.reason ?? "dock.portal.reconcile"
        guard reconcileDockPortalPass(reason: reason) else {
            clearDockPortalReconcile()
            return
        }

        if state.attemptVersion == attemptVersion {
            state.stalledAttemptCount += 1
        }
        scheduleDockPortalReconcileAttempt()
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
