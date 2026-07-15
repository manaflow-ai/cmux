import AppKit

/// Event-driven follow-up state for the Dock portal reconciler.
///
/// Every request performs an immediate pass. Object-scoped observers remain
/// installed only while a visible portal reports that its AppKit host is not
/// mounted yet, and a bounded number of real host/registry lifecycle events can
/// perform follow-up passes. There is no timer, backoff, app-wide event fanout,
/// or focus-driven layout dependency.
@MainActor
final class DockPortalReconcileState {
    var observers: [NSObjectProtocol] = []
    var reason: String?
    var isAttempting = false
    var lifecycleWakeAttemptsRemaining = 0
    var scheduledRequestCount = 0

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

extension DockSplitStore {
    // A normal mount emits ready, window-attachment, and visibility events.
    // Leave room for repeated AppKit churn while bounding a permanently stuck host.
    private static let maxDockPortalLifecycleWakeAttempts = 8

    func scheduleDockPortalReconcile(reason: String) {
        let state = dockPortalReconcileState
        state.scheduledRequestCount += 1
        state.reason = reason
        removeDockPortalReconcileObservers()
        state.lifecycleWakeAttemptsRemaining = Self.maxDockPortalLifecycleWakeAttempts
        installDockPortalReconcileObservers()
        attemptDockPortalReconcile(isLifecycleWake: false)
    }

    private func installDockPortalReconcileObservers() {
        let state = dockPortalReconcileState
        guard state.observers.isEmpty else { return }

        let wake: () -> Void = { [weak self] in
            self?.attemptDockPortalReconcile(isLifecycleWake: true)
        }

        func observe(_ name: Notification.Name, object: AnyObject) {
            state.observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { _ in
                wake()
            })
        }

        for panel in panels.values where panelIsSelectedInVisibleDockPane(panel.id) {
            if let terminal = panel as? TerminalPanel {
                observe(.terminalSurfaceDidBecomeReady, object: terminal.surface)
                observe(.terminalSurfaceHostedViewDidMoveToWindow, object: terminal.surface)
                observe(.terminalPortalVisibilityDidChange, object: terminal.hostedView)
            } else if let browser = panel as? BrowserPanel {
                observe(.browserPortalRegistryDidChange, object: browser.webView)
            }
        }
        for window in dockPortalHostWindows() {
            observe(NSWindow.didUpdateNotification, object: window)
        }
    }

    private func dockPortalHostWindows() -> [NSWindow] {
        var seen: Set<ObjectIdentifier> = []
        var windows: [NSWindow] = []
        func append(_ window: NSWindow?) {
            guard let window, seen.insert(ObjectIdentifier(window)).inserted else { return }
            windows.append(window)
        }

        for panel in panels.values where panelIsSelectedInVisibleDockPane(panel.id) {
            if let terminal = panel as? TerminalPanel {
                append(terminal.hostedView.window)
            } else if let browser = panel as? BrowserPanel {
                append(browser.portalAnchorView.window)
                append(browser.webView.window)
            }
        }
        if let app = AppDelegate.shared,
           let manager = app.dockReferenceTabManager(for: self),
           let windowId = app.windowId(for: manager) {
            append(app.windowForMainWindowId(windowId))
        }
        return windows
    }

    func clearDockPortalReconcile() {
        let state = dockPortalReconcileState
        removeDockPortalReconcileObservers()
        state.lifecycleWakeAttemptsRemaining = 0
        state.reason = nil
    }

    private func removeDockPortalReconcileObservers() {
        let state = dockPortalReconcileState
        state.observers.forEach { NotificationCenter.default.removeObserver($0) }
        state.observers.removeAll()
    }

    private func attemptDockPortalReconcile(isLifecycleWake: Bool) {
        let state = dockPortalReconcileState
        guard !state.isAttempting else { return }
        if isLifecycleWake {
            guard state.lifecycleWakeAttemptsRemaining > 0 else {
                clearDockPortalReconcile()
                return
            }
            state.lifecycleWakeAttemptsRemaining -= 1
        }
        state.isAttempting = true
        defer { state.isAttempting = false }

        let reason = state.reason ?? "dock.portal.reconcile"
        let needsFollowUp = reconcileDockPortalPass(reason: reason)
        if !needsFollowUp || state.observers.isEmpty || state.lifecycleWakeAttemptsRemaining == 0 {
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
