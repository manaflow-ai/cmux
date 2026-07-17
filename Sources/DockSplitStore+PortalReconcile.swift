import AppKit

/// Event-driven follow-up state for the Dock portal reconciler.
///
/// Every request performs an immediate pass. Object-scoped portal observers
/// remain installed only while a visible host is unresolved, so a later real
/// mount event cannot be missed. Window-layout callbacks use a separate bounded
/// budget; exhausting it stops layout churn without abandoning the portal
/// lifecycle signal. There is no timer, backoff, app-wide event fanout, or
/// focus-driven layout dependency.
@MainActor
final class DockPortalReconcileState {
    var portalObservers: [NSObjectProtocol] = []
    var layoutObservers: [NSObjectProtocol] = []
    var reason: String?
    var isAttempting = false
    var layoutWakeAttemptsRemaining = 0
    var scheduledRequestCount = 0

    deinit {
        (portalObservers + layoutObservers).forEach { NotificationCenter.default.removeObserver($0) }
    }
}

extension DockSplitStore {
    // A normal AppKit mount settles within a few window updates. Portal-specific
    // observers stay alive separately if the real host event arrives later.
    private static let maxDockPortalLayoutWakeAttempts = 8

    func scheduleDockPortalReconcile(reason: String) {
        let state = dockPortalReconcileState
        state.scheduledRequestCount += 1
        state.reason = reason
        removeDockPortalReconcileObservers()
        state.layoutWakeAttemptsRemaining = Self.maxDockPortalLayoutWakeAttempts
        installDockPortalReconcileObservers()
        installDockPortalLayoutObservers()
        attemptDockPortalReconcile(isLayoutWake: false)
    }

    private func installDockPortalReconcileObservers() {
        let state = dockPortalReconcileState
        guard state.portalObservers.isEmpty else { return }

        let wake: () -> Void = { [weak self] in
            self?.wakeDockPortalReconcileForLifecycleEvent()
        }

        func observe(_ name: Notification.Name, object: AnyObject) {
            state.portalObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { _ in
                wake()
            })
        }

        for panel in selectedVisibleDockPortalPanels() {
            if let terminal = panel as? TerminalPanel {
                observe(.terminalSurfaceDidBecomeReady, object: terminal.surface)
                observe(.terminalSurfaceHostedViewDidMoveToWindow, object: terminal.surface)
                observe(.terminalPortalVisibilityDidChange, object: terminal.hostedView)
            } else if let browser = panel as? BrowserPanel {
                observe(.browserPortalRegistryDidChange, object: browser.webView)
            }
        }
    }

    private func installDockPortalLayoutObservers() {
        let state = dockPortalReconcileState
        guard state.layoutObservers.isEmpty, state.layoutWakeAttemptsRemaining > 0 else { return }
        let wake: () -> Void = { [weak self] in
            self?.attemptDockPortalReconcile(isLayoutWake: true)
        }
        for window in dockPortalHostWindows() {
            state.layoutObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { _ in
                wake()
            })
        }
    }

    private func wakeDockPortalReconcileForLifecycleEvent() {
        let state = dockPortalReconcileState
        guard !state.isAttempting else { return }
        state.layoutWakeAttemptsRemaining = Self.maxDockPortalLayoutWakeAttempts
        installDockPortalLayoutObservers()
        attemptDockPortalReconcile(isLayoutWake: false)
    }

    private func dockPortalHostWindows() -> [NSWindow] {
        var seen: Set<ObjectIdentifier> = []
        var windows: [NSWindow] = []
        func append(_ window: NSWindow?) {
            guard let window, seen.insert(ObjectIdentifier(window)).inserted else { return }
            windows.append(window)
        }

        for panel in selectedVisibleDockPortalPanels() {
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
        state.layoutWakeAttemptsRemaining = 0
        state.reason = nil
    }

    private func removeDockPortalReconcileObservers() {
        let state = dockPortalReconcileState
        state.portalObservers.forEach { NotificationCenter.default.removeObserver($0) }
        state.portalObservers.removeAll()
        removeDockPortalLayoutObservers()
    }

    private func removeDockPortalLayoutObservers() {
        let state = dockPortalReconcileState
        state.layoutObservers.forEach { NotificationCenter.default.removeObserver($0) }
        state.layoutObservers.removeAll()
    }

    private func attemptDockPortalReconcile(isLayoutWake: Bool) {
        let state = dockPortalReconcileState
        guard !state.isAttempting else { return }
        if isLayoutWake {
            guard state.layoutWakeAttemptsRemaining > 0 else {
                removeDockPortalLayoutObservers()
                return
            }
            state.layoutWakeAttemptsRemaining -= 1
        }
        state.isAttempting = true
        defer { state.isAttempting = false }

        let reason = state.reason ?? "dock.portal.reconcile"
        let needsFollowUp = reconcileDockPortalPass(reason: reason)
        if !needsFollowUp {
            clearDockPortalReconcile()
        } else if state.layoutWakeAttemptsRemaining == 0 {
            removeDockPortalLayoutObservers()
        }
    }

    @discardableResult
    func reconcileDockPortalPass(reason: String) -> Bool {
        var needsFollowUpPass = false
        flushDockWindowLayouts()
        let visiblePanels = selectedVisibleDockPortalPanels()
        let visiblePanelIds = Set(visiblePanels.map(\.id))
        let activePanelId = focusedPanelId

        withCoalescedTerminalViewReattach {
            for panel in panels.values {
                if visiblePanelIds.contains(panel.id) {
                    needsFollowUpPass = reconcileVisibleDockPortalPanel(
                        panel,
                        isActive: panel.id == activePanelId,
                        reason: reason
                    ) || needsFollowUpPass
                } else {
                    applyVisibility(to: panel)
                }
            }
        }

        return needsFollowUpPass
    }

    private func selectedVisibleDockPortalPanels() -> [any Panel] {
        guard isVisibleInUI else { return [] }
        let paneIds = bonsplitController.zoomedPaneId.map { [$0] } ?? bonsplitController.allPaneIds
        return paneIds.compactMap { paneId in
            guard let tabId = bonsplitController.selectedTab(inPane: paneId)?.id else { return nil }
            return panel(for: tabId)
        }
    }

    private func flushDockWindowLayouts() {
        for window in dockPortalHostWindows() where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func reconcileVisibleDockPortalPanel(
        _ panel: any Panel,
        isActive: Bool,
        reason: String
    ) -> Bool {
        if let terminal = panel as? TerminalPanel {
            return reconcileVisibleDockTerminalPortal(terminal, isActive: isActive)
        }
        if let browser = panel as? BrowserPanel {
            return reconcileVisibleDockBrowserPortal(browser, reason: reason)
        }
        return false
    }

    private func reconcileVisibleDockTerminalPortal(_ terminal: TerminalPanel, isActive: Bool) -> Bool {
        var needsFollowUpPass = false
        let hostedView = terminal.hostedView
        hostedView.setVisibleInUI(true)
        hostedView.setActive(isActive)

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
            browser.webView.cmuxBrowserViewportAttachmentSuperview != nil &&
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
