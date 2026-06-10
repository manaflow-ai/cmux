import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Focus reconcile and event-driven layout follow-up
extension Workspace {
    private func reconcileFocusState() {
        guard portalRenderingEnabled else { return }
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedPanelId = panelIdFromSurfaceId(focusedTab.id),
           panels[mappedPanelId] != nil {
            targetPanelId = mappedPanelId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedPanelId = panelIdFromSurfaceId(selectedTab.id),
                      panels[mappedPanelId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedTab.id)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = surfaceIdFromPanelId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let terminalPanel = targetPanel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)
        }
        if let dir = panelDirectories[targetPanelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[targetPanelId]
        pullRequest = panelPullRequests[targetPanelId]
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    func scheduleFocusReconcile() {
        guard portalRenderingEnabled else { return }
#if DEBUG
        if isDetachingCloseTransaction {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
#endif
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.portalRenderingEnabled else {
                self.focusReconcileScheduled = false
                return
            }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    func beginEventDrivenLayoutFollowUp(
        reason: String,
        browserPanelId: UUID? = nil,
        browserExitFocusPanelId: UUID? = nil,
        terminalFocusPanelId: UUID? = nil,
        includeGeometry: Bool = false
    ) {
        guard portalRenderingEnabled else { return }
        layoutFollowUpReason = reason
        if let browserPanelId {
            layoutFollowUpBrowserPanelId = browserPanelId
        }
        if let browserExitFocusPanelId {
            layoutFollowUpBrowserExitFocusPanelId = browserExitFocusPanelId
        }
        if let terminalFocusPanelId {
            layoutFollowUpTerminalFocusPanelId = terminalFocusPanelId
        }
        layoutFollowUpNeedsGeometryPass = layoutFollowUpNeedsGeometryPass || includeGeometry
        layoutFollowUpStalledAttemptCount = 0
        // Invalidate any pending retry whose delay was computed from a stale stall count.
        // Incrementing the version causes old closures to exit early; clearing the flag
        // allows scheduleLayoutFollowUpAttempt() below to enqueue a fresh asyncAfter(0).
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false

        if layoutFollowUpTimeoutWorkItem == nil {
            installLayoutFollowUpObservers()
        }
        refreshLayoutFollowUpTimeout()
        // Use async scheduling instead of a synchronous call here. beginEventDrivenLayoutFollowUp
        // is often invoked from splitTabBar(_:didChangeGeometry:), which fires from inside
        // SwiftUI's .onChange(of: geometry) during an active layout pass. Calling
        // attemptEventDrivenLayoutFollowUp() synchronously in that context causes
        // flushWorkspaceWindowLayouts() → displayIfNeeded() to be called re-entrantly,
        // incrementing AppKit's per-window constraint-pass counter on every display cycle
        // until it exceeds the limit and crashes with NSGenericException.
        // scheduleLayoutFollowUpAttempt() defers via asyncAfter(0) so the flush always
        // happens after the current layout pass completes.
        scheduleLayoutFollowUpAttempt()
    }

    func suppressReparentFocusUntilLayoutFollowUp(
        _ hostedView: GhosttySurfaceScrollView?,
        reason: String
    ) {
        guard let hostedView else { return }
        hostedView.suppressReparentFocus()
        pendingReparentFocusSuppressionViews[ObjectIdentifier(hostedView)] = hostedView
#if DEBUG
        cmuxDebugLog("focus.reparent.suppressPending reason=\(reason) count=\(pendingReparentFocusSuppressionViews.count)")
#endif

        guard portalRenderingEnabled else {
            clearPendingReparentFocusSuppressions(reason: "\(reason).portalDisabled")
            return
        }

        beginEventDrivenLayoutFollowUp(reason: reason, includeGeometry: true)
    }

    private func clearPendingReparentFocusSuppressions(reason: String) {
        guard !pendingReparentFocusSuppressionViews.isEmpty else { return }
        let hostedViews = Array(pendingReparentFocusSuppressionViews.values)
        pendingReparentFocusSuppressionViews.removeAll()
#if DEBUG
        cmuxDebugLog("focus.reparent.clearPending reason=\(reason) count=\(hostedViews.count)")
#endif
        for hostedView in hostedViews {
            hostedView.clearSuppressReparentFocus()
        }
    }

    private func clearReadyPendingReparentFocusSuppressions(reason: String) {
        guard !pendingReparentFocusSuppressionViews.isEmpty else { return }
        let readyKeys = pendingReparentFocusSuppressionViews.compactMap { key, hostedView in
            hostedView.canClearPendingReparentFocusSuppressionAfterLayoutAttempt() ? key : nil
        }
        guard !readyKeys.isEmpty else { return }
        let hostedViews = readyKeys.compactMap { pendingReparentFocusSuppressionViews[$0] }
        for key in readyKeys {
            pendingReparentFocusSuppressionViews.removeValue(forKey: key)
        }
#if DEBUG
        cmuxDebugLog("focus.reparent.clearReady reason=\(reason) count=\(hostedViews.count)")
#endif
        for hostedView in hostedViews {
            hostedView.clearSuppressReparentFocus()
        }
    }

#if DEBUG
    func debugBeginReparentFocusSuppressionForTesting(_ hostedView: GhosttySurfaceScrollView, reason: String) {
        suppressReparentFocusUntilLayoutFollowUp(hostedView, reason: reason)
    }

    func debugAttemptEventDrivenLayoutFollowUpForTesting() {
        attemptEventDrivenLayoutFollowUp()
    }

    func debugHasPendingReparentFocusSuppressionsForTesting() -> Bool {
        !pendingReparentFocusSuppressionViews.isEmpty
    }
#endif

    private func installLayoutFollowUpObservers() {
        guard layoutFollowUpTimeoutWorkItem == nil else { return }

        let enqueueAttempt: () -> Void = { [weak self] in
            self?.scheduleLayoutFollowUpAttempt()
        }

        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpPanelsCancellable = $panels
            .map { _ in () }
            .sink { _ in
                enqueueAttempt()
            }
    }

    private func refreshLayoutFollowUpTimeout() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearLayoutFollowUp()
        }
        layoutFollowUpTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    func clearLayoutFollowUp() {
        clearPendingReparentFocusSuppressions(reason: "workspace.layoutFollowUpEnd")
        layoutFollowUpTimeoutWorkItem?.cancel()
        layoutFollowUpTimeoutWorkItem = nil
        layoutFollowUpObservers.forEach { NotificationCenter.default.removeObserver($0) }
        layoutFollowUpObservers.removeAll()
        layoutFollowUpPanelsCancellable?.cancel()
        layoutFollowUpPanelsCancellable = nil
        layoutFollowUpReason = nil
        layoutFollowUpTerminalFocusPanelId = nil
        layoutFollowUpBrowserPanelId = nil
        layoutFollowUpBrowserExitFocusPanelId = nil
        layoutFollowUpNeedsGeometryPass = false
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false
        layoutFollowUpStalledAttemptCount = 0
    }

    private func scheduleLayoutFollowUpAttempt() {
        guard portalRenderingEnabled else { return }
        guard layoutFollowUpTimeoutWorkItem != nil else { return }
        guard !layoutFollowUpAttemptScheduled else { return }

        layoutFollowUpAttemptScheduled = true
        let delay = layoutFollowUpBackoffDelay()
        let version = layoutFollowUpAttemptVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.layoutFollowUpAttemptVersion == version else { return }
            guard self.portalRenderingEnabled else {
                self.layoutFollowUpAttemptScheduled = false
                self.clearLayoutFollowUp()
                return
            }
            self.layoutFollowUpAttemptScheduled = false
            self.attemptEventDrivenLayoutFollowUp()
        }
    }

    private func layoutFollowUpBackoffDelay() -> TimeInterval {
        guard layoutFollowUpStalledAttemptCount > 0 else { return 0 }
        let baseDelay: TimeInterval = 0.01
        let exponent = min(layoutFollowUpStalledAttemptCount - 1, 5)
        return min(0.25, baseDelay * pow(2.0, Double(exponent)))
    }

    private func flushWorkspaceWindowLayouts() {
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func browserPortalAnchorReady(for browserPanel: BrowserPanel) -> Bool {
        let anchorView = browserPanel.portalAnchorView
        return
            anchorView.window != nil &&
            anchorView.superview != nil &&
            anchorView.bounds.width > 1 &&
            anchorView.bounds.height > 1
    }

    func browserPortalReady(for browserPanel: BrowserPanel) -> Bool {
        browserPortalAnchorReady(for: browserPanel) &&
            browserPanel.webView.window != nil &&
            browserPanel.webView.superview != nil &&
            BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: browserPanel.portalAnchorView)
    }

    private func browserSplitZoomExitFocusNeedsFollowUp(panelId: UUID) -> Bool {
        guard let browserPanel = browserPanel(for: panelId),
              let paneId = paneId(forPanelId: panelId),
              let tabId = surfaceIdFromPanelId(panelId) else {
            return false
        }
        let selectionConverged =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId
        return !selectionConverged || !browserPortalAnchorReady(for: browserPanel)
    }

    private func terminalFocusNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpTerminalFocusPanelId,
              let terminalPanel = terminalPanel(for: panelId) else {
            return false
        }
        return focusedPanelId != panelId || !terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private func browserPanelNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpBrowserPanelId,
              let browserPanel = browserPanel(for: panelId) else {
            return false
        }
        return !browserPortalReady(for: browserPanel)
    }

    private func attemptEventDrivenLayoutFollowUp() {
        guard layoutFollowUpTimeoutWorkItem != nil, !isAttemptingLayoutFollowUp else { return }
        guard portalRenderingEnabled else {
            clearLayoutFollowUp()
            hideAllTerminalPortalViews()
            hideAllBrowserPortalViews()
            return
        }
        isAttemptingLayoutFollowUp = true
        defer { isAttemptingLayoutFollowUp = false }

        flushWorkspaceWindowLayouts()

        let geometryPendingBefore = layoutFollowUpNeedsGeometryPass
        let terminalPortalPendingBefore = terminalPortalVisibilityNeedsFollowUp()
        let browserVisibilityPendingBefore = browserPortalVisibilityNeedsFollowUp()
        let terminalFocusPendingBefore = terminalFocusNeedsFollowUp()
        let browserPanelPendingBefore = browserPanelNeedsFollowUp()
        let browserExitPendingBefore = layoutFollowUpBrowserExitFocusPanelId != nil
        let reparentFocusPendingBefore = !pendingReparentFocusSuppressionViews.isEmpty

        if layoutFollowUpNeedsGeometryPass {
            layoutFollowUpNeedsGeometryPass = reconcileTerminalGeometryPass()
        }

        if let terminalFocusPanelId = layoutFollowUpTerminalFocusPanelId {
            if let terminalPanel = terminalPanel(for: terminalFocusPanelId),
               focusedPanelId == terminalFocusPanelId {
                terminalPanel.hostedView.ensureFocus(for: id, surfaceId: terminalFocusPanelId)
                if terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    layoutFollowUpTerminalFocusPanelId = nil
                }
            } else if terminalPanel(for: terminalFocusPanelId) == nil {
                layoutFollowUpTerminalFocusPanelId = nil
            }
        }

        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        let terminalPortalPending = terminalPortalVisibilityNeedsFollowUp()
        clearReadyPendingReparentFocusSuppressions(reason: "workspace.layoutAttempt")
        let reparentFocusPending = !pendingReparentFocusSuppressionViews.isEmpty

        let reason = layoutFollowUpReason ?? "workspace.layout"
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: reason)
        let browserVisibilityPending = browserPortalVisibilityNeedsFollowUp()

        if let browserPanelId = layoutFollowUpBrowserPanelId {
            if let browserPanel = browserPanel(for: browserPanelId) {
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
                if isReady {
                    layoutFollowUpBrowserPanelId = nil
                }
            } else {
                layoutFollowUpBrowserPanelId = nil
            }
        }

        if let browserExitFocusPanelId = layoutFollowUpBrowserExitFocusPanelId {
            if browserSplitZoomExitFocusNeedsFollowUp(panelId: browserExitFocusPanelId) {
                if browserPanel(for: browserExitFocusPanelId) != nil {
                    focusPanel(browserExitFocusPanelId)
                    scheduleFocusReconcile()
                } else {
                    layoutFollowUpBrowserExitFocusPanelId = nil
                }
            } else {
                layoutFollowUpBrowserExitFocusPanelId = nil
            }
        }

        let terminalFocusPending = terminalFocusNeedsFollowUp()
        let browserPanelPending = browserPanelNeedsFollowUp()
        let browserExitPending = layoutFollowUpBrowserExitFocusPanelId != nil
        let needsMoreWork =
            layoutFollowUpNeedsGeometryPass ||
            terminalPortalPending ||
            browserVisibilityPending ||
            terminalFocusPending ||
            browserPanelPending ||
            browserExitPending ||
            reparentFocusPending

        if !needsMoreWork {
            clearLayoutFollowUp()
            return
        }

        let didMakeProgress =
            (geometryPendingBefore && !layoutFollowUpNeedsGeometryPass) ||
            (terminalPortalPendingBefore && !terminalPortalPending) ||
            (browserVisibilityPendingBefore && !browserVisibilityPending) ||
            (terminalFocusPendingBefore && !terminalFocusPending) ||
            (browserPanelPendingBefore && !browserPanelPending) ||
            (browserExitPendingBefore && !browserExitPending) ||
            (reparentFocusPendingBefore && !reparentFocusPending)

        if didMakeProgress {
            layoutFollowUpStalledAttemptCount = 0
            scheduleLayoutFollowUpAttempt()
        } else {
            layoutFollowUpStalledAttemptCount += 1
        }
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    private func reconcileTerminalGeometryPass() -> Bool {
        var needsFollowUpPass = false
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        // Flush pending AppKit layout first so terminal-host bounds reflect latest split topology.
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            guard visiblePanelIds.contains(terminalPanel.id) else { continue }
            let hostedView = terminalPanel.hostedView
            let hasUsableBounds = hostedView.bounds.width > 1 && hostedView.bounds.height > 1
            let hasSurface = terminalPanel.surface.surface != nil
            let isAttached = terminalPanel.surface.isViewInWindow && hostedView.superview != nil

            // Split close/reparent churn can transiently detach a surviving terminal view.
            // Force one SwiftUI representable update so the portal binding reattaches it.
            if !isAttached || !hasUsableBounds || !hasSurface {
                terminalPanel.requestViewReattach()
                needsFollowUpPass = true
            }

            hostedView.reconcileGeometryNow()
            // Re-check surface after reconcileGeometryNow() which can trigger AppKit
            // layout and view lifecycle changes that free surfaces (#432).
            if terminalPanel.surface.surface != nil {
                terminalPanel.surface.forceRefresh()
            }
            if terminalPanel.surface.surface == nil, isAttached && hasUsableBounds {
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                needsFollowUpPass = true
            }
        }

        return needsFollowUpPass
    }

}
