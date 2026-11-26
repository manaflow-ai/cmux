import CmuxFoundation
public import AppKit
public import Foundation
import CMUXDebugLog

@MainActor
public protocol BrowserHiddenWebViewDiscardManagerDelegate: AnyObject {
    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot { get }
    var hiddenWebViewDiscardHiddenAt: Date? { get }
    var hiddenWebViewDiscardWebViewInstanceID: UUID { get }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    )
    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    )
}

@MainActor
public final class BrowserHiddenWebViewDiscardManager {
    public nonisolated static let systemMemoryPressureReason = "system_memory_pressure"
    public nonisolated static let memoryBudgetReason = "hidden_memory_budget"

    public weak var delegate: (any BrowserHiddenWebViewDiscardManagerDelegate)?

    private var discardTimer: (any DispatchSourceTimer)?
    private var policyObserver: (any NSObjectProtocol)?
    private var systemSleepObservers: [any NSObjectProtocol] = []
    private var systemSleepObserverCenter: NotificationCenter?
    private let policyDefaults: UserDefaults
    private var policyState: BrowserHiddenWebViewDiscardPolicy.ResolvedPolicy
    // Timer work and sleep/wake ingress are serialized by AppKit's main thread.
    // Publish invalidation before hopping to MainActor so queued timers cannot win.
    nonisolated(unsafe) private var scheduleGeneration: UInt64 = 0

    public init(policyDefaults: UserDefaults = .standard) {
        self.policyDefaults = policyDefaults
        self.policyState = BrowserHiddenWebViewDiscardPolicy.resolved(defaults: policyDefaults)
    }

    /// Sleep/wake state used to keep a hidden-webview discard from running in
    /// the fragile window right after system wake
    /// (https://github.com/manaflow-ai/cmux/issues/5261).
    // NSWorkspace notifications use the main queue; actor callers also use that
    // thread. Only this synchronous snapshot crosses the framework callback seam.
    nonisolated(unsafe) private(set) var isSystemSleeping = false
    nonisolated(unsafe) private(set) var lastSystemWakeAt: Date?

    public private(set) var isDiscardedForMemory: Bool = false
    public private(set) var discardedAt: Date?
    public private(set) var lastDiscardReason: String?
    public private(set) var lastRestoreReason: String?
    public private(set) var restoredSessionShouldRenderWebView: Bool?
    public private(set) var isRestoreNavigationPending: Bool = false
    /// Whether the discarded page is a relaunched pane's first load, which
    /// was deferred until the pane is shown rather than unloaded to save
    /// memory.
    public private(set) var isDeferredFirstLoad = false

    /// A per-pane pin that keeps the page live while hidden, even under
    /// system memory pressure.
    public var keepsPageActive = false {
        didSet {
            guard keepsPageActive != oldValue else { return }
            delegate?.hiddenWebViewDiscardManagerPolicyDidChange(self, reason: "keep_active_changed")
        }
    }

    /// Whether a page unloaded to save memory waits for the user to restore
    /// it instead of restoring when its pane is shown.
    public var waitsForManualRestore: Bool {
        isDiscardedForMemory && !isRestoreNavigationPending && !isDeferredFirstLoad
            && !BrowserHiddenWebViewDiscardPolicy.autoRestoresUnloadedPages(defaults: policyDefaults)
    }

    public var hasScheduledDiscard: Bool {
        discardTimer != nil
    }

    /// Whether hidden web views may be discarded at all under the current
    /// settings. Panes skip discard-only preparation when it is off.
    public var isPolicyEnabled: Bool {
        BrowserHiddenWebViewDiscardPolicy.isEnabled(defaults: policyDefaults)
    }

    public func blockers(
        for snapshot: BlockerSnapshot,
        now: Date = Date(),
        urgency: BrowserHiddenWebViewDiscardUrgency = .routine
    ) -> [String] {
        var blockers: [String] = []
        if !BrowserHiddenWebViewDiscardPolicy.isEnabled(defaults: policyDefaults) {
            blockers.append("policy_disabled")
        }
        if keepsPageActive { blockers.append("keep_active") }
        if isSystemSleeping { blockers.append("system_sleeping") }
        let isUnderPressure = urgency == .systemMemoryPressure
        if snapshot.hasRecoverableWebContentTermination && !isUnderPressure {
            blockers.append("webcontent_recovery")
        }
        if snapshot.isClosing { blockers.append("closing") }
        if isDiscardedForMemory { blockers.append("already_discarded") }
        if snapshot.isVisibleInUI { blockers.append("visible") }
        if !snapshot.shouldRenderWebView { blockers.append("not_rendered") }
        if snapshot.hasPendingRemoteNavigation { blockers.append("pending_remote_navigation") }
        if !snapshot.hasCurrentURL { blockers.append("no_url") }
        let allowsRecoverableDiscard = snapshot.hasRecoverableWebContentTermination && isUnderPressure
        if (snapshot.isLoading || snapshot.webViewIsLoading) && !allowsRecoverableDiscard {
            blockers.append("loading")
        }
        if snapshot.hasActiveMainFrameProvisionalNavigation { blockers.append("provisional_navigation") }
        if snapshot.isDownloading || snapshot.activeDownloadCount != 0 { blockers.append("download") }
        if snapshot.isCapturingMedia { blockers.append("media_capture") }
        if snapshot.isPlayingMedia { blockers.append("media_playback") }
        if snapshot.isPictureInPictureActive { blockers.append("picture_in_picture") }
        if snapshot.hasUnrestorableFormInput && !isUnderPressure { blockers.append("form_input") }
        if snapshot.preferredDeveloperToolsVisible || snapshot.isDeveloperToolsVisible {
            blockers.append("developer_tools")
        }
        if snapshot.isElementFullscreenActive { blockers.append("fullscreen") }
        if snapshot.isReactGrabActive { blockers.append("react_grab") }
        if snapshot.isDesignModeActive { blockers.append("design_mode") }
        if snapshot.isVisualAutomationCaptureActive { blockers.append("visual_automation") }
        if snapshot.isMobileBrowserStreamActive { blockers.append("mobile_browser_stream") }
        if snapshot.hasPopups { blockers.append("popup") }
        return blockers
    }

    public func scheduleIfNeeded(
        reason: String,
        now: Date = Date(),
        urgency: BrowserHiddenWebViewDiscardUrgency = .routine
    ) {
        // Under the memory budget, hidden time alone never discards a pane;
        // the budget coordinator picks the pane hidden longest.
        guard BrowserHiddenWebViewDiscardPolicy.mode(defaults: policyDefaults) == .timer else {
            cancel()
            return
        }
        armDiscardCountdown(reason: reason, now: now, urgency: urgency)
    }

    /// Discards the pane once it has been hidden for the delay, counted from
    /// when it was hidden or the system last woke, whichever is later.
    private func armDiscardCountdown(
        reason: String,
        now: Date,
        urgency: BrowserHiddenWebViewDiscardUrgency
    ) {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil

        guard let delegate else { return }
        guard blockers(for: delegate.hiddenWebViewDiscardSnapshot, now: now, urgency: urgency).isEmpty else {
            return
        }

        let observedWebViewInstanceID = delegate.hiddenWebViewDiscardWebViewInstanceID
        let generation = scheduleGeneration
        let hiddenAt = delegate.hiddenWebViewDiscardHiddenAt ?? now
        // Restart the countdown from the latest wake: WebKit pages reconnect and
        // re-navigate right after wake, and replacing/releasing a WKWebView in
        // that window crashed in WebPageProxy::updateActivityState
        // (https://github.com/manaflow-ai/cmux/issues/5261).
        let effectiveHiddenAt = lastSystemWakeAt.map { max(hiddenAt, $0) } ?? hiddenAt
        let elapsed = now.timeIntervalSince(effectiveHiddenAt)
        let hiddenDelay = BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: policyDefaults)
        let remaining = max(0, hiddenDelay - elapsed)
        if remaining <= 0 {
            delegate.hiddenWebViewDiscardManagerDidRequestDiscard(self, reason: reason)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + remaining)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isSystemSleeping else { return }
                guard self.scheduleGeneration == generation else { return }
                guard let delegate = self.delegate else { return }
                guard delegate.hiddenWebViewDiscardWebViewInstanceID == observedWebViewInstanceID else { return }
                self.discardTimer?.cancel()
                self.discardTimer = nil
                delegate.hiddenWebViewDiscardManagerDidRequestDiscard(self, reason: reason)
            }
        }
        discardTimer = timer
        timer.resume()
    }

    @discardableResult
    public func requestImmediateDiscardIfSafe(reason: String, now: Date = Date()) -> Bool {
        guard let delegate else { return false }
        let urgency = BrowserHiddenWebViewDiscardUrgency(reason: reason)
        if urgency != .systemMemoryPressure,
           BrowserHiddenWebViewDiscardPolicy.mode(defaults: policyDefaults) != .timer {
            return false
        }
        guard blockers(for: delegate.hiddenWebViewDiscardSnapshot, now: now, urgency: urgency).isEmpty else {
            return false
        }
        // A deferred pressure discard arms a countdown in either mode. Routine
        // rescheduling may replace it; the monitor asks again on every sample
        // while pressure lasts.
        guard delegate.hiddenWebViewDiscardHiddenAt != nil else {
            armDiscardCountdown(reason: reason, now: now, urgency: urgency)
            return false
        }
        // Memory pressure bypasses the hidden-duration delay, not the WebKit post-wake crash guard.
        guard !isInPostWakeDiscardDelay(now: now) else {
            armDiscardCountdown(reason: reason, now: now, urgency: urgency)
            return false
        }

        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil
        delegate.hiddenWebViewDiscardManagerDidRequestDiscard(self, reason: reason)
        return true
    }

    /// Whether the memory budget may discard the pane now: nothing blocks a
    /// discard, and the pane has been hidden for the delay since it was
    /// hidden or the system last woke, whichever is later.
    public func isEligibleForMemoryBudgetDiscard(now: Date = Date()) -> Bool {
        guard let delegate, let hiddenAt = delegate.hiddenWebViewDiscardHiddenAt else { return false }
        guard blockers(for: delegate.hiddenWebViewDiscardSnapshot, now: now).isEmpty else { return false }
        let effectiveHiddenAt = lastSystemWakeAt.map { max(hiddenAt, $0) } ?? hiddenAt
        let hiddenDelay = BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: policyDefaults)
        return now.timeIntervalSince(effectiveHiddenAt) >= hiddenDelay
    }

    /// Discards the pane to bring hidden web content back under the memory
    /// budget, if it is still eligible.
    ///
    /// - Returns: Whether the discard was requested.
    @discardableResult
    public func requestMemoryBudgetDiscard(now: Date = Date()) -> Bool {
        guard let delegate, isEligibleForMemoryBudgetDiscard(now: now) else { return false }
        cancel()
        delegate.hiddenWebViewDiscardManagerDidRequestDiscard(self, reason: Self.memoryBudgetReason)
        return true
    }

    public func cancel() {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil
    }

    /// Tracks system sleep/wake so discard countdowns armed before sleep do not
    /// fire shortly after wake. Injectable center for tests.
    public func installSystemSleepObservers(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard systemSleepObservers.isEmpty else { return }
        systemSleepObserverCenter = center
        systemSleepObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.receiveSystemSleepTransition(isSleeping: true)
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.receiveSystemSleepTransition(isSleeping: false)
            }
        ]
    }

    /// Publishes the main-thread notification barrier before deferred timer work.
    private nonisolated func receiveSystemSleepTransition(isSleeping: Bool) {
        let now = Date()
        isSystemSleeping = isSleeping
        if !isSleeping { lastSystemWakeAt = now }
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        Task { @MainActor [weak self] in
            guard let self, self.scheduleGeneration == generation else { return }
            if isSleeping {
                self.noteSystemWillSleep()
            } else {
                self.noteSystemDidWake(now: now)
            }
        }
    }

    public func noteSystemWillSleep() {
        isSystemSleeping = true
        let hadScheduledDiscard = hasScheduledDiscard
        cancel()
#if DEBUG
        if hadScheduledDiscard {
            CMUXDebugLog.logDebugEvent("browser.discard.sleep canceledArmedTimer=1")
        }
#endif
    }

    public func noteSystemDidWake(now: Date = Date()) {
        isSystemSleeping = false
        lastSystemWakeAt = now
        scheduleIfNeeded(reason: "system_did_wake", now: now)
#if DEBUG
        CMUXDebugLog.logDebugEvent("browser.discard.wake rearmed=\(hasScheduledDiscard ? 1 : 0)")
#endif
    }

    public func installPolicyObserver() {
        policyState = BrowserHiddenWebViewDiscardPolicy.resolved(defaults: policyDefaults)
        guard policyObserver == nil else { return }
        policyObserver = NotificationCenter.default.addUserDefaultsObserver(object: nil) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handlePolicyDefaultsChanged()
            }
        }
    }

    public nonisolated func stop() {
        Task { @MainActor [self] in
            stopOnMainActor()
        }
    }

    public func markDiscarded(reason: String, now: Date, isDeferredFirstLoad: Bool = false) {
        isDiscardedForMemory = true
        isRestoreNavigationPending = false
        self.isDeferredFirstLoad = isDeferredFirstLoad
        discardedAt = now
        lastDiscardReason = reason
        updateRestoredSessionRenderIntent(true)
    }

    @discardableResult
    public func restoreIfNeeded(reason: String, force: Bool = false, performRestore: () -> Void) -> Bool {
        guard isDiscardedForMemory else { return false }
        cancel()
        if isRestoreNavigationPending {
            // An explicit user reload restarts an in-flight restore instead of
            // being swallowed by the pending dedup.
            guard force else { return true }
            isRestoreNavigationPending = false
        }
        lastRestoreReason = reason
        updateRestoredSessionRenderIntent(nil)
        performRestore()
        return true
    }

    public func noteRestoreNavigationStarted(reason: String) {
        guard isDiscardedForMemory else { return }
        isRestoreNavigationPending = true
#if DEBUG
        CMUXDebugLog.logDebugEvent("browser.discard.restoreNavigation.start reason=\(reason)")
#endif
    }

    @discardableResult
    public func noteRestoreNavigationCommitted(reason: String) -> Bool {
        isRestoreNavigationPending = false
        return clearDiscardState(reason: reason)
    }

    public func noteRestoreNavigationDidNotCommit(reason: String) {
        guard isDiscardedForMemory else { return }
        isRestoreNavigationPending = false
#if DEBUG
        CMUXDebugLog.logDebugEvent("browser.discard.restoreNavigation.didNotCommit reason=\(reason)")
#endif
    }

    @discardableResult
    public func reactivateWithoutNavigation(reason: String, performReactivate: () -> Void) -> Bool {
        guard isDiscardedForMemory else { return false }
        cancel()
        performReactivate()
        return clearDiscardState(reason: reason)
    }

    public func updateRestoredSessionRenderIntent(_ shouldRenderWebView: Bool?) {
        restoredSessionShouldRenderWebView = shouldRenderWebView
    }

    @discardableResult
    func clearDiscardState(reason: String) -> Bool {
        guard isDiscardedForMemory else { return false }
        isDiscardedForMemory = false
        isRestoreNavigationPending = false
        isDeferredFirstLoad = false
        discardedAt = nil
        lastRestoreReason = reason
        updateRestoredSessionRenderIntent(nil)
        return true
    }

    public func resetMetadata() {
        cancel()
        isDiscardedForMemory = false
        isRestoreNavigationPending = false
        isDeferredFirstLoad = false
        discardedAt = nil
        lastDiscardReason = nil
        lastRestoreReason = nil
        updateRestoredSessionRenderIntent(nil)
    }

    private func handlePolicyDefaultsChanged() {
        let nextPolicyState = BrowserHiddenWebViewDiscardPolicy.resolved(defaults: policyDefaults)
        guard policyState != nextPolicyState else { return }
        policyState = nextPolicyState
        delegate?.hiddenWebViewDiscardManagerPolicyDidChange(self, reason: "policy_changed")
    }

    private func isInPostWakeDiscardDelay(now: Date) -> Bool {
        guard let lastSystemWakeAt else { return false }
        return now.timeIntervalSince(lastSystemWakeAt) < BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: policyDefaults)
    }

    private func stopOnMainActor() {
        cancel()
        if let policyObserver {
            NotificationCenter.default.removeObserver(policyObserver)
            self.policyObserver = nil
        }
        if let center = systemSleepObserverCenter {
            for observer in systemSleepObservers {
                center.removeObserver(observer)
            }
        }
        systemSleepObservers.removeAll()
        systemSleepObserverCenter = nil
    }
}
