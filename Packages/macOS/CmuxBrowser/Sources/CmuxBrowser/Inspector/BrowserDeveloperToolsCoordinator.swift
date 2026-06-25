public import AppKit
public import WebKit
public import Foundation
import Observation

/// Owns the WebKit Web Inspector (developer tools) subsystem for one browser panel.
///
/// cmux drives Web Inspector through WebKit's private `_inspector` SPI (see
/// ``WKWebView/cmuxInspectorObject()`` and ``WebInspectorTeardownService``). The
/// inspector survives WKWebView detach/reattach churn during split and layout
/// changes, so this coordinator persists the user's open/closed intent, the
/// docked-vs-detached presentation preference, and the retry/transition machinery
/// that reopens the inspector after each reattach. All WebKit and app-side reach is
/// routed through an injected ``BrowserDeveloperToolsHosting`` seam so this type has
/// no `BrowserPanel`/`AppDelegate` dependency; the conformer holds its panel weakly.
///
/// Behavior is a faithful lift of the former `BrowserPanel` developer-tools
/// methods: the same `DispatchQueue.main.asyncAfter` retry/settle cadence, the same
/// selector probes, the same grace deadlines, and the same debug logging. The
/// `DispatchQueue` scheduling and `MainActor.assumeIsolated` close observer are
/// preserved verbatim and are slated for a later `Clock`/`AsyncStream`
/// modernization pass.
@MainActor
@Observable
public final class BrowserDeveloperToolsCoordinator {
    /// How the user last had the Web Inspector presented, persisted across WebKit
    /// detach/reattach so a reopen restores the same docked-vs-detached shape.
    public enum DeveloperToolsPresentation: Sendable {
        /// No inspector layout has been observed yet, so neither dock nor detached
        /// is preferred; the next reveal infers the shape from WebKit's own state.
        case unknown
        /// The inspector was last shown docked inside the panel's container view.
        case attached
        /// The inspector was last shown in its own detached WebKit window.
        case detached
    }

    private let host: any BrowserDeveloperToolsHosting
    private let logSink: (@MainActor @Sendable (String) -> Void)?

    /// The coordinator's authoritative copy of the open/closed intent. The panel's
    /// `@Published preferredDeveloperToolsVisible` is a mirror driven by
    /// ``setPreferredDeveloperToolsVisible(_:)``; reads inside the coordinator use
    /// this property so the two never diverge.
    public private(set) var preferredDeveloperToolsVisible: Bool = false

    // Persist user intent across WebKit detach/reattach churn (split/layout updates).
    private var preferredDeveloperToolsPresentation: DeveloperToolsPresentation = .unknown
    private var forceDeveloperToolsRefreshOnNextAttach: Bool = false
    private var developerToolsRestoreRetryWorkItem: DispatchWorkItem?
    private var developerToolsRestoreRetryAttempt: Int = 0
    private let developerToolsRestoreRetryDelay: TimeInterval = 0.05
    private let developerToolsRestoreRetryMaxAttempts: Int = 40
    private let developerToolsDetachedOpenGracePeriod: TimeInterval = 0.35
    private var developerToolsDetachedOpenGraceDeadline: Date?
    private var developerToolsTransitionTargetVisible: Bool?
    private var pendingDeveloperToolsTransitionTargetVisible: Bool?
    private var developerToolsTransitionSettleWorkItem: DispatchWorkItem?
    private var developerToolsVisibilityLossCheckWorkItem: DispatchWorkItem?
    private let developerToolsTransitionSettleDelay: TimeInterval = 0.15
    private let developerToolsAttachedManualCloseDetectionDelay: TimeInterval = 0.35
    private var developerToolsLastAttachedHostAt: Date?
    private var developerToolsLastKnownVisibleAt: Date?
    private var detachedDeveloperToolsWindowCloseObserver: NSObjectProtocol?
    private var preferredAttachedDeveloperToolsWidth: CGFloat?
    private var preferredAttachedDeveloperToolsWidthFraction: CGFloat?

    /// Creates a coordinator bound to one panel's developer-tools host seam.
    ///
    /// - Parameters:
    ///   - host: The seam exposing the panel's live `WKWebView`, window
    ///     enumeration, and app-side side effects. Held strongly; the conformer is
    ///     expected to hold its own owner weakly to avoid a retain cycle.
    ///   - logSink: Optional debug-log sink invoked on the main actor with the same
    ///     messages the panel previously emitted. Pass `nil` in release.
    public init(
        host: any BrowserDeveloperToolsHosting,
        logSink: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.host = host
        self.logSink = logSink
        installDetachedDeveloperToolsWindowCloseObserver()
    }

    deinit {
        developerToolsRestoreRetryWorkItem?.cancel()
        developerToolsRestoreRetryWorkItem = nil
        developerToolsTransitionSettleWorkItem?.cancel()
        developerToolsTransitionSettleWorkItem = nil
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        developerToolsVisibilityLossCheckWorkItem = nil
        if let detachedDeveloperToolsWindowCloseObserver {
            NotificationCenter.default.removeObserver(detachedDeveloperToolsWindowCloseObserver)
        }
    }

    // MARK: - Window / layout queries

    private func detachedDeveloperToolsWindows() -> [NSWindow] {
        let mainWindow = host.developerToolsWebView?.window
        let detector = WebInspectorLayoutDetector()
        return host.developerToolsApplicationWindows.filter { candidate in
            if let mainWindow, candidate === mainWindow {
                return false
            }
            return detector.isDetachedInspectorWindow(candidate)
        }
    }

    private func hasAttachedDeveloperToolsLayout() -> Bool {
        guard let container = host.developerToolsWebView?.superview else { return false }
        let detector = WebInspectorLayoutDetector()
        return detector.visibleDescendants(in: container)
            .contains { detector.isVisibleSideDockInspectorCandidate($0) && detector.isInspectorView($0) }
    }

    // MARK: - Preference mutators

    private func setPreferredDeveloperToolsPresentation(_ next: DeveloperToolsPresentation) {
        guard preferredDeveloperToolsPresentation != next else { return }
        preferredDeveloperToolsPresentation = next
        DispatchQueue.main.async { [weak self] in
            self?.host.developerToolsPresentationPreferenceDidChange()
        }
    }

    private func setPreferredDeveloperToolsVisible(_ next: Bool) {
        guard preferredDeveloperToolsVisible != next else { return }
        preferredDeveloperToolsVisible = next
        host.setPreferredDeveloperToolsVisible(next)
    }

    private func reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden() {
        guard !preferredDeveloperToolsVisible, !isDeveloperToolsVisible() else { return }
        host.reevaluateHiddenWebViewDiscardScheduling(reason: "developer_tools_visibility_changed")
    }

    private func syncDeveloperToolsPresentationPreferenceFromUI() {
        if hasAttachedDeveloperToolsLayout() {
            setPreferredDeveloperToolsPresentation(.attached)
            developerToolsDetachedOpenGraceDeadline = nil
        } else if !detachedDeveloperToolsWindows().isEmpty {
            setPreferredDeveloperToolsPresentation(.detached)
        }
    }

    // MARK: - Detached inspector window observers

    private func installDetachedDeveloperToolsWindowCloseObserver() {
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
                guard WebInspectorLayoutDetector().isDetachedInspectorWindow(window) else { return false }
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
                self.log(
                    "browser.devtools detachedClose.manual panel=\(self.host.developerToolsPanelDebugID) " +
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

    /// Closes the inspector in response to a user-initiated close of its detached
    /// WebKit window, clearing the open intent so it does not reopen on reattach.
    ///
    /// - Parameters:
    ///   - window: The detached inspector window the user closed.
    ///   - source: A short tag identifying the close trigger, used in debug logs.
    /// - Returns: `true` if the window belonged to this panel and the inspector was
    ///   torn down, `false` if the window was unrelated.
    @discardableResult
    public func closeDeveloperToolsFromDetachedInspectorWindowUserAction(
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
        log(
            "browser.devtools detachedClose.\(source) panel=\(host.developerToolsPanelDebugID) " +
            "closed=\(closed ? 1 : 0) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return closed
    }

    private func detachedDeveloperToolsWindowBelongsToPanel(_ window: NSWindow) -> Bool {
        guard let frontendWebView = host.developerToolsWebView?.cmuxInspectorFrontendWebView(),
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
              let mainWindow = host.developerToolsWebView?.window else { return }
        let detector = WebInspectorLayoutDetector()
        for window in host.developerToolsApplicationWindows where window !== mainWindow && detector.isDetachedInspectorWindow(window) {
#if DEBUG
            log(
                "browser.devtools strayWindow.close panel=\(host.developerToolsPanelDebugID) " +
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

    // MARK: - Inspector reveal / conceal

    private func prepareDeveloperToolsForRevealIfNeeded(_ inspector: NSObject) {
        if preferredDeveloperToolsPresentation != .unknown {
            guard preferredDeveloperToolsPresentation == .attached else { return }
            guard let webView = host.developerToolsWebView,
                  webView.superview != nil, webView.window != nil else { return }
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

    // MARK: - Transition machinery

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
            log(
                "browser.devtools transition.queue panel=\(host.developerToolsPanelDebugID) " +
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
        guard let inspector = host.developerToolsWebView?.cmuxInspectorObject() else { return false }

        let isVisibleSelector = NSSelectorFromString("isVisible")
        let visible = inspector.cmuxCallBool(selector: isVisibleSelector) ?? false
        setPreferredDeveloperToolsVisible(targetVisible)
        developerToolsTransitionTargetVisible = targetVisible
        if targetVisible {
            host.reevaluateHiddenWebViewDiscardScheduling(reason: "developer_tools_visibility_changed")
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

    // MARK: - Public entry points

    /// Toggles the Web Inspector to the opposite of its current effective intent,
    /// queuing the transition if one is already settling.
    ///
    /// - Returns: `true` if the toggle was accepted (performed or queued).
    @discardableResult
    public func toggleDeveloperTools() -> Bool {
#if DEBUG
        log(
            "browser.devtools toggle.begin panel=\(host.developerToolsPanelDebugID) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        let targetVisible = !effectiveDeveloperToolsVisibilityIntent()
        let handled = enqueueDeveloperToolsVisibilityTransition(to: targetVisible, source: "toggle")
#if DEBUG
        log(
            "browser.devtools toggle.end panel=\(host.developerToolsPanelDebugID) targetVisible=\(targetVisible ? 1 : 0) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.log(
                "browser.devtools toggle.tick panel=\(self.host.developerToolsPanelDebugID) " +
                "\(self.debugDeveloperToolsStateSummary()) \(self.debugDeveloperToolsGeometrySummary())"
            )
        }
#endif
        return handled
    }

    /// Reveals the Web Inspector, queuing the transition if one is already settling.
    ///
    /// - Returns: `true` if the show was accepted (performed or queued).
    @discardableResult
    public func showDeveloperTools() -> Bool {
        return enqueueDeveloperToolsVisibilityTransition(to: true, source: "show")
    }

    /// Reveals the Web Inspector and then selects its Console tab, probing the
    /// OS-specific private console selectors until one responds.
    ///
    /// - Returns: `true` if the inspector was shown (the console selection is best
    ///   effort and does not affect the result).
    @discardableResult
    public func showDeveloperToolsConsole() -> Bool {
        guard showDeveloperTools() else { return false }
        guard !isDeveloperToolsTransitionInFlight else { return true }
        guard let inspector = host.developerToolsWebView?.cmuxInspectorObject() else { return true }
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

    /// Force-closes the inspector and cancels all pending retry/settle/grace state,
    /// used when the panel or its WKWebView is being torn down.
    ///
    /// - Returns: `true` if WebKit reported the inspector closed.
    @discardableResult
    public func closeDeveloperToolsForTeardown() -> Bool {
        developerToolsTransitionSettleWorkItem?.cancel()
        developerToolsTransitionSettleWorkItem = nil
        pendingDeveloperToolsTransitionTargetVisible = nil
        developerToolsTransitionTargetVisible = nil
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        cancelDeveloperToolsRestoreRetry()

        let closed: Bool
        if let webView = host.developerToolsWebView {
            closed = WebInspectorTeardownService().closeInspector(for: webView)
        } else {
            closed = false
        }
        setPreferredDeveloperToolsVisible(false)
        return closed
    }

    /// Called before WKWebView detaches so manual inspector closes are respected.
    public func syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: Bool = false) {
        guard let inspector = host.developerToolsWebView?.cmuxInspectorObject() else { return }
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

    /// Records that the panel's WKWebView host attached, anchoring the manual-close
    /// detection grace window. Resets the grace only on genuine inspector churn (see
    /// the inline note), so plain re-renders do not defer a user's manual close.
    public func noteDeveloperToolsHostAttached() {
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

    /// Schedules a deferred check that consumes a user's manual inspector close once
    /// the attach grace window has elapsed, replacing any previously scheduled check.
    public func scheduleDeveloperToolsVisibilityLossCheck() {
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

    /// Cancels any pending visibility-loss check scheduled by
    /// ``scheduleDeveloperToolsVisibilityLossCheck()``.
    public func cancelPendingDeveloperToolsVisibilityLossCheck() {
        developerToolsVisibilityLossCheckWorkItem?.cancel()
        developerToolsVisibilityLossCheckWorkItem = nil
    }

    /// Detects that the user manually closed a docked inspector after the attach
    /// grace window and, if so, clears the open intent and related retry state.
    ///
    /// - Parameter inspector: An already-resolved inspector object to reuse; when
    ///   `nil` the inspector is fetched from the host's WKWebView.
    /// - Returns: `true` if a manual close was detected and consumed.
    @discardableResult
    public func consumeAttachedDeveloperToolsManualCloseIfNeeded(inspector: NSObject? = nil) -> Bool {
        guard preferredDeveloperToolsVisible else { return false }
        guard preferredDeveloperToolsPresentation != .detached else { return false }
        guard !isDeveloperToolsTransitionInFlight else { return false }
        guard let webView = host.developerToolsWebView,
              webView.superview != nil, webView.window != nil else { return false }
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
        log(
            "browser.devtools attachedClose.consume panel=\(host.developerToolsPanelDebugID) " +
            "\(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return true
    }

    /// Called after WKWebView reattaches to keep inspector stable across split/layout churn.
    public func restoreDeveloperToolsAfterAttachIfNeeded() {
        guard preferredDeveloperToolsVisible else {
            cancelDeveloperToolsRestoreRetry()
            forceDeveloperToolsRefreshOnNextAttach = false
            return
        }
        guard !isDeveloperToolsTransitionInFlight else { return }
        guard let inspector = host.developerToolsWebView?.cmuxInspectorObject() else {
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
                log("browser.devtools refresh.consumeVisible panel=\(host.developerToolsPanelDebugID) \(debugDeveloperToolsStateSummary())")
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
            log(
                "browser.devtools detachedClose.consume panel=\(host.developerToolsPanelDebugID) " +
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
            log("browser.devtools refresh.forceShowWhenHidden panel=\(host.developerToolsPanelDebugID) \(debugDeveloperToolsStateSummary())")
        }
        #endif
        // WebKit inspector show can trigger transient first-responder churn while
        // panel attachment is still stabilizing. Keep this auto-restore path from
        // mutating first responder so AppKit doesn't walk tearing-down responder chains.
        host.withBrowserFirstResponderBypass {
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

    /// Whether WebKit currently reports the Web Inspector as visible.
    ///
    /// - Returns: `true` if the live inspector's `isVisible` is set, `false` when no
    ///   inspector exists or it is hidden.
    @discardableResult
    public func isDeveloperToolsVisible() -> Bool {
        guard let inspector = host.developerToolsWebView?.cmuxInspectorObject() else { return false }
        return inspector.cmuxCallBool(selector: NSSelectorFromString("isVisible")) ?? false
    }

    /// Hides the Web Inspector, queuing the transition if one is already settling.
    ///
    /// - Returns: `true` if the hide was accepted (performed or queued).
    @discardableResult
    public func hideDeveloperTools() -> Bool {
        return enqueueDeveloperToolsVisibilityTransition(to: false, source: "hide")
    }

    /// During split/layout transitions SwiftUI can briefly mark the browser surface hidden
    /// while its container is off-window. Avoid detaching in that transient phase if
    /// DevTools is intended to remain open, because detach/reattach can blank inspector content.
    public func shouldPreserveWebViewAttachmentDuringTransientHide() -> Bool {
        preferredDeveloperToolsVisible
            && !WebInspectorLayoutDetector().hasSideDockedLayout(in: host.developerToolsWebView?.superview)
    }

    /// Requests that the next WKWebView reattach force-reopen the inspector, used
    /// after layout changes that can blank inspector content. No-op unless the
    /// inspector is currently intended to be open.
    ///
    /// - Parameter reason: A short tag describing the trigger, used in debug logs.
    public func requestDeveloperToolsRefreshAfterNextAttach(reason: String) {
        guard preferredDeveloperToolsVisible else { return }
        forceDeveloperToolsRefreshOnNextAttach = true
        #if DEBUG
        log("browser.devtools refresh.request panel=\(host.developerToolsPanelDebugID) reason=\(reason) \(debugDeveloperToolsStateSummary())")
        #endif
    }

    /// Whether a forced inspector reopen is queued for the next reattach.
    ///
    /// - Returns: `true` if ``requestDeveloperToolsRefreshAfterNextAttach(reason:)``
    ///   armed a pending refresh that has not yet been consumed.
    public func hasPendingDeveloperToolsRefreshAfterAttach() -> Bool {
        forceDeveloperToolsRefreshOnNextAttach
    }

    /// Whether the open intent should survive a transient WKWebView detach, e.g. a
    /// pending refresh/restore is in flight or the web view is currently off-window.
    ///
    /// - Returns: `true` if the panel should keep treating the inspector as intended
    ///   open while detached.
    public func shouldPreserveDeveloperToolsIntentWhileDetached() -> Bool {
        preferredDeveloperToolsVisible &&
            (
                forceDeveloperToolsRefreshOnNextAttach ||
                developerToolsRestoreRetryWorkItem != nil ||
                host.developerToolsWebView?.superview == nil ||
                host.developerToolsWebView?.window == nil
            )
    }

    /// Whether the panel should host the WKWebView in local-inline mode so a docked
    /// inspector renders correctly. False when no inspector is intended/visible, when
    /// the preference is detached, or when a detached inspector window already exists.
    ///
    /// - Returns: `true` if local-inline hosting is required for a docked inspector.
    public func shouldUseLocalInlineDeveloperToolsHosting() -> Bool {
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible() else { return false }
        if preferredDeveloperToolsPresentation == .detached {
            return false
        }
        return detachedDeveloperToolsWindows().isEmpty
    }

    /// Records the user's preferred docked-inspector width, storing both the absolute
    /// value and its fraction of the container so the width can be restored after a
    /// resize.
    ///
    /// - Parameters:
    ///   - width: The desired inspector width in points; clamped to be non-negative.
    ///   - containerBounds: The container's current bounds, used to derive the
    ///     width-as-fraction; a zero-width container clears the stored fraction.
    public func recordPreferredAttachedDeveloperToolsWidth(_ width: CGFloat, containerBounds: NSRect) {
        let normalizedWidth = max(0, width)
        preferredAttachedDeveloperToolsWidth = normalizedWidth
        guard containerBounds.width > 0 else {
            preferredAttachedDeveloperToolsWidthFraction = nil
            return
        }
        preferredAttachedDeveloperToolsWidthFraction = normalizedWidth / containerBounds.width
    }

    /// The user's preferred docked-inspector width as last recorded.
    ///
    /// - Returns: The absolute `width` and its `widthFraction` of the container, each
    ///   `nil` if not yet recorded.
    public func preferredAttachedDeveloperToolsWidthState() -> (width: CGFloat?, widthFraction: CGFloat?) {
        (preferredAttachedDeveloperToolsWidth, preferredAttachedDeveloperToolsWidthFraction)
    }

    // MARK: - Restore retry

    private func scheduleDeveloperToolsRestoreRetry() {
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

    /// Cancels any pending restore-after-attach retry and resets the attempt counter.
    public func cancelDeveloperToolsRestoreRetry() {
        developerToolsRestoreRetryWorkItem?.cancel()
        developerToolsRestoreRetryWorkItem = nil
        developerToolsRestoreRetryAttempt = 0
    }

    // MARK: - Context-reset hook

    /// Resets all developer-tools intent and presentation state when the panel's
    /// workspace context changes. Mirrors the panel's former inline reset block.
    public func resetForWorkspaceContextChange() {
        _ = hideDeveloperTools()
        cancelDeveloperToolsRestoreRetry()
        setPreferredDeveloperToolsVisible(false)
        preferredDeveloperToolsPresentation = .unknown
        forceDeveloperToolsRefreshOnNextAttach = false
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsRestoreRetryAttempt = 0
        preferredAttachedDeveloperToolsWidth = nil
        preferredAttachedDeveloperToolsWidthFraction = nil
    }

    private func log(_ message: String) {
        logSink?(message)
    }
}

#if DEBUG
extension BrowserDeveloperToolsCoordinator {
    private static func debugRectDescription(_ rect: NSRect) -> String {
        String(
            format: "%.1f,%.1f %.1fx%.1f",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    private static func debugObjectToken(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    func debugDeveloperToolsStateSummary() -> String {
        let preferred = preferredDeveloperToolsVisible ? 1 : 0
        let visible = isDeveloperToolsVisible() ? 1 : 0
        let webView = host.developerToolsWebView
        let inspector = webView?.cmuxInspectorObject() == nil ? 0 : 1
        let attached = webView?.superview == nil ? 0 : 1
        let inWindow = webView?.window == nil ? 0 : 1
        let forceRefresh = forceDeveloperToolsRefreshOnNextAttach ? 1 : 0
        let transitionTarget = developerToolsTransitionTargetVisible.map { $0 ? "1" : "0" } ?? "nil"
        let pendingTarget = pendingDeveloperToolsTransitionTargetVisible.map { $0 ? "1" : "0" } ?? "nil"
        return "pref=\(preferred) vis=\(visible) inspector=\(inspector) attached=\(attached) inWindow=\(inWindow) restoreRetry=\(developerToolsRestoreRetryAttempt) forceRefresh=\(forceRefresh) tx=\(transitionTarget) pending=\(pendingTarget)"
    }

    func debugDeveloperToolsGeometrySummary() -> String {
        let webView = host.developerToolsWebView
        let container = webView?.superview
        let containerBounds = container?.bounds ?? .zero
        let webFrame = webView?.frame ?? .zero
        let inspectorInsets = max(0, containerBounds.height - webFrame.height)
        let inspectorOverflow = max(0, webFrame.maxY - containerBounds.maxY)
        let inspectorHeightApprox = max(inspectorInsets, inspectorOverflow)
        let inspectorSubviews = container.map { WebInspectorLayoutDetector().inspectorSubviewCount(in: $0) } ?? 0
        let containerType = container.map { String(describing: type(of: $0)) } ?? "nil"
        let webBounds = webView?.bounds ?? .zero
        let webWindowNumber = webView?.window?.windowNumber ?? -1
        return "webFrame=\(Self.debugRectDescription(webFrame)) webBounds=\(Self.debugRectDescription(webBounds)) webWin=\(webWindowNumber) super=\(Self.debugObjectToken(container)) superType=\(containerType) superBounds=\(Self.debugRectDescription(containerBounds)) inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) inspectorInsets=\(String(format: "%.1f", inspectorInsets)) inspectorOverflow=\(String(format: "%.1f", inspectorOverflow)) inspectorSubviews=\(inspectorSubviews)"
    }
}
#endif
