import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Developer tools
extension BrowserPanel {
    private static func windowContainsInspectorViews(_ root: NSView) -> Bool {
        if cmuxIsWebInspectorObject(root) {
            return true
        }
        for subview in root.subviews where windowContainsInspectorViews(subview) {
            return true
        }
        return false
    }

    static func isDetachedInspectorWindow(_ window: NSWindow) -> Bool {
        guard window.title.hasPrefix("Web Inspector") else { return false }
        guard let contentView = window.contentView else { return false }
        return windowContainsInspectorViews(contentView)
    }

    private func detachedDeveloperToolsWindows() -> [NSWindow] {
        let mainWindow = webView.window
        return NSApp.windows.filter { candidate in
            if let mainWindow, candidate === mainWindow {
                return false
            }
            return Self.isDetachedInspectorWindow(candidate)
        }
    }

    private func hasAttachedDeveloperToolsLayout() -> Bool {
        guard let container = webView.superview else { return false }
        return Self.visibleDescendants(in: container)
            .contains { Self.isVisibleSideDockInspectorCandidate($0) && Self.isInspectorView($0) }
    }

    private func setPreferredDeveloperToolsPresentation(_ next: DeveloperToolsPresentation) {
        guard preferredDeveloperToolsPresentation != next else { return }
        // `preferredDeveloperToolsPresentation` is `@ObservationIgnored`
        // DevTools bookkeeping (never `@Published`; no view body reads it), so
        // this mutation fires no change notification. The pre-migration
        // deferred `objectWillChange.send()` existed only to keep the notify
        // out of in-progress view updates; with no observing body it is moot.
        preferredDeveloperToolsPresentation = next
    }

    func setPreferredDeveloperToolsVisible(_ next: Bool) {
        guard preferredDeveloperToolsVisible != next else { return }
        preferredDeveloperToolsVisible = next
    }

    private func reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden() {
        guard !preferredDeveloperToolsVisible, !isDeveloperToolsVisible() else { return }
        reevaluateHiddenWebViewDiscardScheduling(reason: "developer_tools_visibility_changed")
    }

    private func syncDeveloperToolsPresentationPreferenceFromUI() {
        if hasAttachedDeveloperToolsLayout() {
            setPreferredDeveloperToolsPresentation(.attached)
            developerToolsDetachedOpenGraceDeadline = nil
        } else if !detachedDeveloperToolsWindows().isEmpty {
            setPreferredDeveloperToolsPresentation(.detached)
        }
    }

    func installDetachedDeveloperToolsWindowCloseObserver() {
        guard detachedDeveloperToolsWindowCloseObserver == nil else { return }
        detachedDeveloperToolsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow else { return }
            guard Thread.isMainThread else { return }
            let handledDetachedInspector = MainActor.assumeIsolated {
                guard Self.isDetachedInspectorWindow(window) else { return false }
                return self.closeDeveloperToolsFromDetachedInspectorWindowWillClose(window)
            }
            guard handledDetachedInspector else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.preferredDeveloperToolsPresentation == .detached else { return }
                guard self.preferredDeveloperToolsVisible else { return }
                guard !self.isDeveloperToolsVisible() else { return }
                self.developerToolsDetachedOpenGraceDeadline = nil
                self.setPreferredDeveloperToolsVisible(false)
                self.reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
                self.cancelDeveloperToolsRestoreRetry()
#if DEBUG
                cmuxDebugLog(
                    "browser.devtools detachedClose.manual panel=\(self.id.uuidString.prefix(5)) " +
                    "\(self.debugDeveloperToolsStateSummary()) \(self.debugDeveloperToolsGeometrySummary())"
                )
#endif
            }
        }
    }

    @discardableResult
    private func closeDeveloperToolsFromDetachedInspectorWindowWillClose(_ window: NSWindow) -> Bool {
        closeDeveloperToolsFromDetachedInspectorWindow(window, source: "willClose")
    }

    @discardableResult
    func closeDeveloperToolsFromDetachedInspectorWindowUserAction(
        _ window: NSWindow,
        source: String
    ) -> Bool {
        closeDeveloperToolsFromDetachedInspectorWindow(window, source: source)
    }

    @discardableResult
    private func closeDeveloperToolsFromDetachedInspectorWindow(
        _ window: NSWindow,
        source: String
    ) -> Bool {
        guard detachedDeveloperToolsWindowBelongsToPanel(window) else { return false }
        let closed = closeDeveloperToolsForTeardown()
#if DEBUG
        cmuxDebugLog(
            "browser.devtools detachedClose.\(source) panel=\(id.uuidString.prefix(5)) " +
            "closed=\(closed ? 1 : 0) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return closed
    }

    private func detachedDeveloperToolsWindowBelongsToPanel(_ window: NSWindow) -> Bool {
        guard let frontendWebView = webView.cmuxInspectorFrontendWebView(),
              let contentView = window.contentView else {
            return false
        }
        return frontendWebView === contentView || frontendWebView.isDescendant(of: contentView)
    }

    private func shouldDismissDetachedDeveloperToolsWindows() -> Bool {
        preferredDeveloperToolsPresentation == .attached
    }

    private func dismissDetachedDeveloperToolsWindowsIfNeeded() {
        guard shouldDismissDetachedDeveloperToolsWindows() else { return }
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible(),
              let mainWindow = webView.window else { return }
        for window in NSApp.windows where window !== mainWindow && Self.isDetachedInspectorWindow(window) {
#if DEBUG
            cmuxDebugLog(
                "browser.devtools strayWindow.close panel=\(id.uuidString.prefix(5)) " +
                "title=\(window.title) frame=\(NSStringFromRect(window.frame))"
            )
#endif
            window.close()
        }
    }

    private func scheduleDetachedDeveloperToolsWindowDismissal() {
        guard shouldDismissDetachedDeveloperToolsWindows() else { return }
        for delay in [0.0, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.dismissDetachedDeveloperToolsWindowsIfNeeded()
            }
        }
    }

    private func prepareDeveloperToolsForRevealIfNeeded(_ inspector: NSObject) {
        if preferredDeveloperToolsPresentation != .unknown {
            guard preferredDeveloperToolsPresentation == .attached else { return }
            guard webView.superview != nil, webView.window != nil else { return }
            guard inspector.cmuxCallBool(selector: NSSelectorFromString("isAttached")) == false else { return }
        }
        let attachSelector = NSSelectorFromString("attach")
        guard inspector.responds(to: attachSelector) else { return }
        inspector.cmuxCallVoid(selector: attachSelector)
    }

    @discardableResult
    private func revealDeveloperTools(_ inspector: NSObject) -> Bool {
        let isVisibleSelector = NSSelectorFromString("isVisible")
        if inspector.cmuxCallBool(selector: isVisibleSelector) ?? false {
            developerToolsDetachedOpenGraceDeadline = nil
            developerToolsLastKnownVisibleAt = Date()
            return true
        }

        prepareDeveloperToolsForRevealIfNeeded(inspector)

        let showSelector = NSSelectorFromString("show")
        guard inspector.responds(to: showSelector) else { return false }
        inspector.cmuxCallVoid(selector: showSelector)
        let visibleAfterShow = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
        if visibleAfterShow {
            developerToolsLastKnownVisibleAt = Date()
        }
        if preferredDeveloperToolsPresentation == .detached {
            developerToolsDetachedOpenGraceDeadline = visibleAfterShow
                ? nil
                : Date().addingTimeInterval(developerToolsDetachedOpenGracePeriod)
        } else {
            developerToolsDetachedOpenGraceDeadline = nil
        }
        return visibleAfterShow
    }

    @discardableResult
    private func concealDeveloperTools(_ inspector: NSObject) -> Bool {
        let isVisibleSelector = NSSelectorFromString("isVisible")
        guard inspector.cmuxCallBool(selector: isVisibleSelector) ?? false else { return true }

        var invokedSelector = false
        for rawSelector in ["hide", "close"] {
            let selector = NSSelectorFromString(rawSelector)
            guard inspector.responds(to: selector) else { continue }
            invokedSelector = true
            inspector.cmuxCallVoid(selector: selector)
            if !(inspector.cmuxCallBool(selector: isVisibleSelector) ?? false) {
                return true
            }
        }

        guard invokedSelector else { return false }
        return !(inspector.cmuxCallBool(selector: isVisibleSelector) ?? false)
    }

    private var isDeveloperToolsTransitionInFlight: Bool {
        developerToolsTransitionSettleWorkItem != nil
    }

    private func effectiveDeveloperToolsVisibilityIntent() -> Bool {
        if let pendingDeveloperToolsTransitionTargetVisible {
            return pendingDeveloperToolsTransitionTargetVisible
        }
        if let developerToolsTransitionTargetVisible {
            return developerToolsTransitionTargetVisible
        }
        return isDeveloperToolsVisible()
    }

    private func scheduleDeveloperToolsTransitionSettle(source: String) {
        developerToolsTransitionSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.developerToolsTransitionSettleWorkItem = nil
            self?.finishDeveloperToolsTransition(source: source)
        }
        developerToolsTransitionSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + developerToolsTransitionSettleDelay, execute: workItem)
    }

    private func finishDeveloperToolsTransition(source: String) {
        let pendingTargetVisible = pendingDeveloperToolsTransitionTargetVisible
        pendingDeveloperToolsTransitionTargetVisible = nil
        developerToolsTransitionTargetVisible = nil

        guard let pendingTargetVisible else { return }
        guard pendingTargetVisible != isDeveloperToolsVisible() else { return }
        _ = performDeveloperToolsVisibilityTransition(to: pendingTargetVisible, source: "\(source).queued")
    }

    @discardableResult
    private func enqueueDeveloperToolsVisibilityTransition(
        to targetVisible: Bool,
        source: String
    ) -> Bool {
        if isDeveloperToolsTransitionInFlight {
            pendingDeveloperToolsTransitionTargetVisible = targetVisible
            setPreferredDeveloperToolsVisible(targetVisible)
            if !targetVisible {
                developerToolsDetachedOpenGraceDeadline = nil
                forceDeveloperToolsRefreshOnNextAttach = false
                cancelDeveloperToolsRestoreRetry()
            }
#if DEBUG
            cmuxDebugLog(
                "browser.devtools transition.queue panel=\(id.uuidString.prefix(5)) " +
                "source=\(source) target=\(targetVisible ? 1 : 0) \(debugDeveloperToolsStateSummary())"
            )
#endif
            return true
        }

        return performDeveloperToolsVisibilityTransition(to: targetVisible, source: source)
    }

    @discardableResult
    private func performDeveloperToolsVisibilityTransition(
        to targetVisible: Bool,
        source: String
    ) -> Bool {
        guard let inspector = webView.cmuxInspectorObject() else { return false }

        let isVisibleSelector = NSSelectorFromString("isVisible")
        let visible = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
        setPreferredDeveloperToolsVisible(targetVisible)
        developerToolsTransitionTargetVisible = targetVisible
        if targetVisible {
            reevaluateHiddenWebViewDiscardScheduling(reason: "developer_tools_visibility_changed")
        }

        if targetVisible {
            if !visible {
                _ = revealDeveloperTools(inspector)
            } else {
                developerToolsDetachedOpenGraceDeadline = nil
            }
        } else {
            if visible {
                syncDeveloperToolsPresentationPreferenceFromUI()
                guard concealDeveloperTools(inspector) else {
                    developerToolsTransitionTargetVisible = nil
                    return false
                }
            }
            developerToolsDetachedOpenGraceDeadline = nil
        }

        if targetVisible {
            let visibleAfterTransition = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
            if visibleAfterTransition {
                syncDeveloperToolsPresentationPreferenceFromUI()
                cancelDeveloperToolsRestoreRetry()
                scheduleDetachedDeveloperToolsWindowDismissal()
            } else {
                developerToolsRestoreRetryAttempt = 0
                scheduleDeveloperToolsRestoreRetry()
            }
        } else {
            cancelDeveloperToolsRestoreRetry()
            forceDeveloperToolsRefreshOnNextAttach = false
            reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
        }

        if visible != targetVisible {
            scheduleDeveloperToolsTransitionSettle(source: source)
        } else {
            developerToolsTransitionTargetVisible = nil
        }

        return true
    }

    @discardableResult
    func toggleDeveloperTools() -> Bool {
#if DEBUG
        cmuxDebugLog(
            "browser.devtools toggle.begin panel=\(id.uuidString.prefix(5)) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        let targetVisible = !effectiveDeveloperToolsVisibilityIntent()
        let handled = enqueueDeveloperToolsVisibilityTransition(to: targetVisible, source: "toggle")
#if DEBUG
        cmuxDebugLog(
            "browser.devtools toggle.end panel=\(id.uuidString.prefix(5)) targetVisible=\(targetVisible ? 1 : 0) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            cmuxDebugLog(
                "browser.devtools toggle.tick panel=\(self.id.uuidString.prefix(5)) " +
                "\(self.debugDeveloperToolsStateSummary()) \(self.debugDeveloperToolsGeometrySummary())"
            )
        }
#endif
        return handled
    }

    @discardableResult
    func showDeveloperTools() -> Bool {
        return enqueueDeveloperToolsVisibilityTransition(to: true, source: "show")
    }

    @discardableResult
    func showDeveloperToolsConsole() -> Bool {
        guard showDeveloperTools() else { return false }
        guard !isDeveloperToolsTransitionInFlight else { return true }
        guard let inspector = webView.cmuxInspectorObject() else { return true }
        // WebKit private inspector API differs by OS; try known console selectors.
        let consoleSelectors = [
            "showConsole",
            "showConsoleTab",
            "showConsoleView",
        ]
        for raw in consoleSelectors {
            let selector = NSSelectorFromString(raw)
            if inspector.responds(to: selector) {
                inspector.cmuxCallVoid(selector: selector)
                break
            }
        }
        return true
    }

    @discardableResult
    func closeDeveloperToolsForTeardown() -> Bool {
        developerToolsTransitionSettleWorkItem?.cancel()
        developerToolsTransitionSettleWorkItem = nil
        pendingDeveloperToolsTransitionTargetVisible = nil
        developerToolsTransitionTargetVisible = nil
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        cancelDeveloperToolsRestoreRetry()

        let closed = WebViewInspectorTeardown.closeInspector(for: webView)
        setPreferredDeveloperToolsVisible(false)
        return closed
    }

    /// Called before WKWebView detaches so manual inspector closes are respected.
    func syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: Bool = false) {
        guard let inspector = webView.cmuxInspectorObject() else { return }
        guard let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) else { return }
        if isDeveloperToolsTransitionInFlight {
            let targetVisible = pendingDeveloperToolsTransitionTargetVisible ?? developerToolsTransitionTargetVisible ?? visible
            setPreferredDeveloperToolsVisible(targetVisible)
            if targetVisible, visible {
                developerToolsDetachedOpenGraceDeadline = nil
                syncDeveloperToolsPresentationPreferenceFromUI()
                cancelDeveloperToolsRestoreRetry()
            } else if !targetVisible {
                developerToolsDetachedOpenGraceDeadline = nil
                forceDeveloperToolsRefreshOnNextAttach = false
                cancelDeveloperToolsRestoreRetry()
            }
            return
        }
        if visible {
            developerToolsDetachedOpenGraceDeadline = nil
            syncDeveloperToolsPresentationPreferenceFromUI()
            setPreferredDeveloperToolsVisible(true)
            developerToolsLastKnownVisibleAt = Date()
            cancelDeveloperToolsRestoreRetry()
            return
        }
        if preserveVisibleIntent && preferredDeveloperToolsVisible {
            return
        }
        setPreferredDeveloperToolsVisible(false)
        developerToolsLastKnownVisibleAt = nil
        reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
        cancelDeveloperToolsRestoreRetry()
    }

    func noteDeveloperToolsHostAttached() {
        cancelPendingDeveloperToolsVisibilityLossCheck()
        // `developerToolsLastAttachedHostAt` anchors the manual-close detection
        // grace (see `consumeAttachedDeveloperToolsManualCloseIfNeeded`). Refresh it
        // only when this attach reflects genuine inspector churn: the inspector is
        // currently visible, a forced refresh is pending, or a restore retry is in
        // flight. While DevTools intent is set the browser stays in local-inline
        // hosting, so `BrowserPanelView` re-runs this on every `updateNSView`. A
        // plain re-render (e.g. navigating to another page) is not a reattach;
        // resetting the grace there would defer a user's manual inspector close
        // indefinitely and let `restoreDeveloperToolsAfterAttachIfNeeded` reopen it.
        if developerToolsLastAttachedHostAt == nil || hasActiveDeveloperToolsReattachReason {
            developerToolsLastAttachedHostAt = Date()
        }
        if isDeveloperToolsVisible() {
            developerToolsLastKnownVisibleAt = Date()
        }
    }

    /// Whether a host attach should count as genuine inspector churn that resets
    /// the manual-close grace window, rather than a steady-state re-render while
    /// the inspector is already closed.
    private var hasActiveDeveloperToolsReattachReason: Bool {
        isDeveloperToolsVisible()
            || forceDeveloperToolsRefreshOnNextAttach
            || developerToolsRestoreRetryWorkItem != nil
    }

    func scheduleDeveloperToolsVisibilityLossCheck() {
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        let attachedAge = developerToolsLastAttachedHostAt.map { Date().timeIntervalSince($0) } ?? 0
        let delay = max(
            developerToolsTransitionSettleDelay,
            developerToolsAttachedManualCloseDetectionDelay - attachedAge
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.developerToolsVisibilityLossCheckWorkItem = nil
            _ = self.consumeAttachedDeveloperToolsManualCloseIfNeeded()
        }
        developerToolsVisibilityLossCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
    }

    func cancelPendingDeveloperToolsVisibilityLossCheck() {
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        developerToolsVisibilityLossCheckWorkItem = nil
    }

    @discardableResult
    func consumeAttachedDeveloperToolsManualCloseIfNeeded(inspector: NSObject? = nil) -> Bool {
        guard preferredDeveloperToolsVisible else { return false }
        guard preferredDeveloperToolsPresentation != .detached else { return false }
        guard !isDeveloperToolsTransitionInFlight else { return false }
        guard webView.superview != nil, webView.window != nil else { return false }
        guard let developerToolsLastAttachedHostAt else { return false }
        guard Date().timeIntervalSince(developerToolsLastAttachedHostAt) >= developerToolsAttachedManualCloseDetectionDelay else {
            return false
        }
        guard developerToolsLastKnownVisibleAt != nil else { return false }
        guard let inspector = inspector ?? webView.cmuxInspectorObject() else { return false }
        guard let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) else { return false }
        guard !visible else {
            developerToolsLastKnownVisibleAt = Date()
            return false
        }

        setPreferredDeveloperToolsVisible(false)
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
        cancelDeveloperToolsRestoreRetry()
#if DEBUG
        cmuxDebugLog(
            "browser.devtools attachedClose.consume panel=\(id.uuidString.prefix(5)) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return true
    }

    /// Called after WKWebView reattaches to keep inspector stable across split/layout churn.
    func restoreDeveloperToolsAfterAttachIfNeeded() {
        guard preferredDeveloperToolsVisible else {
            cancelDeveloperToolsRestoreRetry()
            forceDeveloperToolsRefreshOnNextAttach = false
            return
        }
        guard !isDeveloperToolsTransitionInFlight else { return }
        guard let inspector = webView.cmuxInspectorObject() else {
            scheduleDeveloperToolsRestoreRetry()
            return
        }

        let shouldForceRefresh = forceDeveloperToolsRefreshOnNextAttach
        forceDeveloperToolsRefreshOnNextAttach = false

        let visible = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visible {
            developerToolsDetachedOpenGraceDeadline = nil
            syncDeveloperToolsPresentationPreferenceFromUI()
            developerToolsLastKnownVisibleAt = Date()
            #if DEBUG
            if shouldForceRefresh {
                cmuxDebugLog("browser.devtools refresh.consumeVisible panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
            }
            #endif
            cancelDeveloperToolsRestoreRetry()
            return
        }

        let detachedOpenStillSettling = developerToolsDetachedOpenGraceDeadline.map { $0 > Date() } ?? false
        if preferredDeveloperToolsPresentation == .detached && !detachedOpenStillSettling {
            setPreferredDeveloperToolsVisible(false)
            developerToolsDetachedOpenGraceDeadline = nil
            cancelDeveloperToolsRestoreRetry()
#if DEBUG
            cmuxDebugLog(
                "browser.devtools detachedClose.consume panel=\(id.uuidString.prefix(5)) " +
                "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
            )
#endif
            return
        }

        if consumeAttachedDeveloperToolsManualCloseIfNeeded(inspector: inspector) {
            return
        }

        #if DEBUG
        if shouldForceRefresh {
            cmuxDebugLog("browser.devtools refresh.forceShowWhenHidden panel=\(id.uuidString.prefix(5)) \(debugDeveloperToolsStateSummary())")
        }
        #endif
        // WebKit inspector show can trigger transient first-responder churn while
        // panel attachment is still stabilizing. Keep this auto-restore path from
        // mutating first responder so AppKit doesn't walk tearing-down responder chains.
        cmuxWithWindowFirstResponderBypass {
            _ = revealDeveloperTools(inspector)
        }
        setPreferredDeveloperToolsVisible(true)
        let visibleAfterShow = inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
        if visibleAfterShow {
            syncDeveloperToolsPresentationPreferenceFromUI()
            developerToolsLastKnownVisibleAt = Date()
            cancelDeveloperToolsRestoreRetry()
            scheduleDetachedDeveloperToolsWindowDismissal()
        } else {
            scheduleDeveloperToolsRestoreRetry()
        }
    }

    @discardableResult
    func isDeveloperToolsVisible() -> Bool {
        guard let inspector = webView.cmuxInspectorObject() else { return false }
        return inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
    }

    @discardableResult
    func hideDeveloperTools() -> Bool {
        return enqueueDeveloperToolsVisibilityTransition(to: false, source: "hide")
    }

    /// During split/layout transitions SwiftUI can briefly mark the browser surface hidden
    /// while its container is off-window. Avoid detaching in that transient phase if
    /// DevTools is intended to remain open, because detach/reattach can blank inspector content.
    func shouldPreserveWebViewAttachmentDuringTransientHide() -> Bool {
        preferredDeveloperToolsVisible && !hasSideDockedDeveloperToolsLayout()
    }

    func requestDeveloperToolsRefreshAfterNextAttach(reason: String) {
        guard preferredDeveloperToolsVisible else { return }
        forceDeveloperToolsRefreshOnNextAttach = true
        #if DEBUG
        cmuxDebugLog("browser.devtools refresh.request panel=\(id.uuidString.prefix(5)) reason=\(reason) \(debugDeveloperToolsStateSummary())")
        #endif
    }

    func hasPendingDeveloperToolsRefreshAfterAttach() -> Bool {
        forceDeveloperToolsRefreshOnNextAttach
    }

    func shouldPreserveDeveloperToolsIntentWhileDetached() -> Bool {
        preferredDeveloperToolsVisible &&
            (
                forceDeveloperToolsRefreshOnNextAttach ||
                developerToolsRestoreRetryWorkItem != nil ||
                webView.superview == nil ||
                webView.window == nil
            )
    }

    func shouldUseLocalInlineDeveloperToolsHosting() -> Bool {
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible() else { return false }
        if preferredDeveloperToolsPresentation == .detached {
            return false
        }
        return detachedDeveloperToolsWindows().isEmpty
    }

    func recordPreferredAttachedDeveloperToolsWidth(_ width: CGFloat, containerBounds: NSRect) {
        let normalizedWidth = max(0, width)
        preferredAttachedDeveloperToolsWidth = normalizedWidth
        guard containerBounds.width > 0 else {
            preferredAttachedDeveloperToolsWidthFraction = nil
            return
        }
        preferredAttachedDeveloperToolsWidthFraction = normalizedWidth / containerBounds.width
    }

    func preferredAttachedDeveloperToolsWidthState() -> (width: CGFloat?, widthFraction: CGFloat?) {
        (preferredAttachedDeveloperToolsWidth, preferredAttachedDeveloperToolsWidthFraction)
    }

    func scheduleDeveloperToolsRestoreRetry() {
        guard preferredDeveloperToolsVisible else { return }
        guard developerToolsRestoreRetryWorkItem == nil else { return }
        guard developerToolsRestoreRetryAttempt < developerToolsRestoreRetryMaxAttempts else { return }

        developerToolsRestoreRetryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.developerToolsRestoreRetryWorkItem = nil
            self.restoreDeveloperToolsAfterAttachIfNeeded()
        }
        developerToolsRestoreRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + developerToolsRestoreRetryDelay, execute: work)
    }

    func cancelDeveloperToolsRestoreRetry() {
        developerToolsRestoreRetryWorkItem?.cancel()
        developerToolsRestoreRetryWorkItem = nil
        developerToolsRestoreRetryAttempt = 0
    }
    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    func hasSideDockedDeveloperToolsLayout() -> Bool {
        guard let container = webView.superview else { return false }
        return Self.visibleDescendants(in: container)
            .filter { Self.isVisibleSideDockInspectorCandidate($0) && Self.isInspectorView($0) }
            .contains { inspectorCandidate in
                hasSideDockedInspectorSibling(startingAt: inspectorCandidate, root: container)
            }
    }

    func hasSideDockedInspectorSibling(startingAt inspectorLeaf: NSView, root: NSView) -> Bool {
        var current: NSView? = inspectorLeaf

        while let inspectorView = current, inspectorView !== root {
            guard let containerView = inspectorView.superview else { break }
            let hasSideDockedSibling = containerView.subviews.contains { candidate in
                guard Self.isVisibleSideDockSiblingCandidate(candidate) else { return false }
                guard candidate !== inspectorView else { return false }
                let horizontallyAdjacent =
                    candidate.frame.maxX <= inspectorView.frame.minX + 1 ||
                    candidate.frame.minX >= inspectorView.frame.maxX - 1
                guard horizontallyAdjacent else { return false }
                return Self.verticalOverlap(between: candidate.frame, and: inspectorView.frame) > 8
            }
            if hasSideDockedSibling {
                return true
            }

            current = containerView
        }

        return false
    }

    static func visibleDescendants(in root: NSView) -> [NSView] {
        var descendants: [NSView] = []
        var stack = Array(root.subviews.reversed())
        while let view = stack.popLast() {
            descendants.append(view)
            stack.append(contentsOf: view.subviews.reversed())
        }
        return descendants
    }

    static func isInspectorView(_ view: NSView) -> Bool {
        cmuxIsWebInspectorObject(view)
    }

    static func isVisibleSideDockInspectorCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    static func isVisibleSideDockSiblingCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }
}
