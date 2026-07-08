import AppKit
import Foundation

@MainActor
protocol BrowserHiddenWebViewDiscardManagerDelegate: AnyObject {
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
final class BrowserHiddenWebViewDiscardManager {
    struct BlockerSnapshot {
        let isClosing: Bool
        let isVisibleInUI: Bool
        let shouldRenderWebView: Bool
        let hasPendingRemoteNavigation: Bool
        let hasCurrentURL: Bool
        let isLoading: Bool
        let webViewIsLoading: Bool
        let hasActiveMainFrameProvisionalNavigation: Bool
        let isDownloading: Bool
        let activeDownloadCount: Int
        let preferredDeveloperToolsVisible: Bool
        let isDeveloperToolsVisible: Bool
        let isElementFullscreenActive: Bool
        let isReactGrabActive: Bool
        let isVisualAutomationCaptureActive: Bool
        let hasPopups: Bool
        let isCapturingMedia: Bool
        let hasAudibleMedia: Bool
    }

    weak var delegate: BrowserHiddenWebViewDiscardManagerDelegate?

    private var discardTimer: DispatchSourceTimer?
    private var blockedRecheckTimer: DispatchSourceTimer?
    private let policyDefaults: UserDefaults
    private let eventCenter: BrowserHiddenWebViewDiscardEventCenter
    private var isSubscribedToEventCenter = false
    private var scheduleGeneration: UInt64 = 0

    init(
        policyDefaults: UserDefaults = .standard,
        eventCenter: BrowserHiddenWebViewDiscardEventCenter = .shared
    ) {
        self.policyDefaults = policyDefaults
        self.eventCenter = eventCenter
    }

    /// Sleep/wake state used to keep a hidden-webview discard from running in
    /// the fragile window right after system wake
    /// (https://github.com/manaflow-ai/cmux/issues/5261).
    private(set) var isSystemSleeping = false
    private(set) var lastSystemWakeAt: Date?

    private(set) var isDiscardedForMemory: Bool = false
    private(set) var discardedAt: Date?
    private(set) var lastDiscardReason: String?
    private(set) var lastRestoreReason: String?
    private(set) var restoredSessionShouldRenderWebView: Bool?

    var hasScheduledDiscard: Bool {
        discardTimer != nil
    }

    var hasScheduledBlockedRecheck: Bool {
        blockedRecheckTimer != nil
    }

    func blockers(for snapshot: BlockerSnapshot) -> [String] {
        var blockers: [String] = []
        if !BrowserHiddenWebViewDiscardPolicy.isEnabled(defaults: policyDefaults) {
            blockers.append("policy_disabled")
        }
        if isSystemSleeping { blockers.append("system_sleeping") }
        if snapshot.isClosing { blockers.append("closing") }
        if isDiscardedForMemory { blockers.append("already_discarded") }
        if snapshot.isVisibleInUI { blockers.append("visible") }
        if !snapshot.shouldRenderWebView { blockers.append("not_rendered") }
        if snapshot.hasPendingRemoteNavigation { blockers.append("pending_remote_navigation") }
        if !snapshot.hasCurrentURL { blockers.append("no_url") }
        if snapshot.isLoading || snapshot.webViewIsLoading { blockers.append("loading") }
        if snapshot.hasActiveMainFrameProvisionalNavigation { blockers.append("provisional_navigation") }
        if snapshot.isDownloading || snapshot.activeDownloadCount != 0 { blockers.append("download") }
        if snapshot.isCapturingMedia { blockers.append("media_capture") }
        if snapshot.hasAudibleMedia { blockers.append("media_playback") }
        if snapshot.isDeveloperToolsVisible {
            blockers.append("developer_tools")
        }
        if snapshot.isElementFullscreenActive { blockers.append("fullscreen") }
        if snapshot.isReactGrabActive { blockers.append("react_grab") }
        if snapshot.isVisualAutomationCaptureActive { blockers.append("visual_automation") }
        if snapshot.hasPopups { blockers.append("popup") }
        return blockers
    }

    func scheduleIfNeeded(reason: String, now: Date = Date()) {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil
        blockedRecheckTimer?.cancel()
        blockedRecheckTimer = nil

        guard let delegate else { return }
        let snapshot = delegate.hiddenWebViewDiscardSnapshot
        guard blockers(for: snapshot).isEmpty else {
            guard shouldScheduleBlockedRecheck(for: snapshot) else { return }
            scheduleBlockedRecheckIfNeeded(
                reason: reason,
                observedWebViewInstanceID: delegate.hiddenWebViewDiscardWebViewInstanceID,
                generation: scheduleGeneration
            )
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
            MainActor.assumeIsolated {
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
    func performScheduledBlockedRecheckForTesting(now: Date = Date()) -> Bool {
        guard blockedRecheckTimer != nil else { return false }
        blockedRecheckTimer?.cancel()
        blockedRecheckTimer = nil
        scheduleIfNeeded(reason: "blocked_recheck", now: now)
        return true
    }

    @discardableResult
    func requestImmediateDiscardIfSafe(reason: String, now: Date = Date()) -> Bool {
        guard let delegate else { return false }
        guard blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty else { return false }
        guard delegate.hiddenWebViewDiscardHiddenAt != nil else {
            scheduleIfNeeded(reason: reason, now: now)
            return false
        }
        // Memory pressure bypasses the hidden-duration delay, not the WebKit post-wake crash guard.
        guard !isInPostWakeDiscardDelay(now: now) else {
            scheduleIfNeeded(reason: reason, now: now)
            return false
        }

        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil
        blockedRecheckTimer?.cancel()
        blockedRecheckTimer = nil
        delegate.hiddenWebViewDiscardManagerDidRequestDiscard(self, reason: reason)
        return true
    }

    func cancel() {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil
        blockedRecheckTimer?.cancel()
        blockedRecheckTimer = nil
    }

    func noteSystemWillSleep() {
        isSystemSleeping = true
        let hadScheduledDiscard = hasScheduledDiscard
        cancel()
#if DEBUG
        if hadScheduledDiscard {
            cmuxDebugLog("browser.discard.sleep canceledArmedTimer=1")
        }
#endif
    }

    func noteSystemDidWake(now: Date = Date()) {
        isSystemSleeping = false
        lastSystemWakeAt = now
        scheduleIfNeeded(reason: "system_did_wake", now: now)
#if DEBUG
        cmuxDebugLog("browser.discard.wake rearmed=\(hasScheduledDiscard ? 1 : 0)")
#endif
    }

    func installEventCenterSubscription() {
        guard !isSubscribedToEventCenter else { return }
        eventCenter.add(self)
        isSubscribedToEventCenter = true
    }

    nonisolated func stop() {
        Task { @MainActor [self] in
            stopOnMainActor()
        }
    }

    func markDiscarded(reason: String, now: Date) {
        isDiscardedForMemory = true
        discardedAt = now
        lastDiscardReason = reason
        updateRestoredSessionRenderIntent(true)
    }

    @discardableResult
    func restoreIfNeeded(reason: String, performRestore: () -> Void) -> Bool {
        guard isDiscardedForMemory else { return false }
        cancel()
        guard clearDiscardState(reason: reason) else { return false }
        updateRestoredSessionRenderIntent(nil)
        performRestore()
        return true
    }

    @discardableResult
    func reactivateWithoutNavigation(reason: String, performReactivate: () -> Void) -> Bool {
        guard isDiscardedForMemory else { return false }
        cancel()
        guard clearDiscardState(reason: reason) else { return false }
        updateRestoredSessionRenderIntent(nil)
        performReactivate()
        return true
    }

    func updateRestoredSessionRenderIntent(_ shouldRenderWebView: Bool?) {
        restoredSessionShouldRenderWebView = shouldRenderWebView
    }

    @discardableResult
    func clearDiscardState(reason: String) -> Bool {
        guard isDiscardedForMemory else { return false }
        isDiscardedForMemory = false
        discardedAt = nil
        lastRestoreReason = reason
        return true
    }

    func resetMetadata() {
        cancel()
        isDiscardedForMemory = false
        discardedAt = nil
        lastDiscardReason = nil
        lastRestoreReason = nil
        updateRestoredSessionRenderIntent(nil)
    }

    private func isInPostWakeDiscardDelay(now: Date) -> Bool {
        guard let lastSystemWakeAt else { return false }
        return now.timeIntervalSince(lastSystemWakeAt) < BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: policyDefaults)
    }

    private func stopOnMainActor() {
        cancel()
        if isSubscribedToEventCenter {
            eventCenter.remove(self)
            isSubscribedToEventCenter = false
        }
    }

    private func shouldScheduleBlockedRecheck(for snapshot: BlockerSnapshot) -> Bool {
        guard BrowserHiddenWebViewDiscardPolicy.isEnabled(defaults: policyDefaults) else { return false }
        guard !snapshot.isVisibleInUI, !snapshot.isClosing, !isDiscardedForMemory else { return false }
        return true
    }

    private func scheduleBlockedRecheckIfNeeded(
        reason: String,
        observedWebViewInstanceID: UUID,
        generation: UInt64
    ) {
        guard blockedRecheckTimer == nil else { return }
        let policy = BrowserHiddenWebViewDiscardPolicy.resolved(defaults: policyDefaults)
        let delay = Self.blockedRecheckDelay(for: policy)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.scheduleGeneration == generation else { return }
                guard let delegate = self.delegate else { return }
                guard delegate.hiddenWebViewDiscardWebViewInstanceID == observedWebViewInstanceID else { return }
                self.blockedRecheckTimer?.cancel()
                self.blockedRecheckTimer = nil
                self.scheduleIfNeeded(reason: reason, now: Date())
            }
        }
        blockedRecheckTimer = timer
        timer.resume()
    }

    static func blockedRecheckDelay(
        for policy: BrowserHiddenWebViewDiscardPolicy.ResolvedPolicy
    ) -> TimeInterval {
        max(60, policy.hiddenDelay)
    }
}

extension BrowserHiddenWebViewDiscardManager: BrowserHiddenWebViewDiscardEventSubscriber {
    func discardPolicyDidChange(_: BrowserHiddenWebViewDiscardPolicy.ResolvedPolicy) {
        delegate?.hiddenWebViewDiscardManagerPolicyDidChange(self, reason: "policy_changed")
    }

    func systemWillSleep() {
        noteSystemWillSleep()
    }

    func systemDidWake() {
        noteSystemDidWake()
    }
}
