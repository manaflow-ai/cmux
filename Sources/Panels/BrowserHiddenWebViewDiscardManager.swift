import AppKit
import CmuxBrowser
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
        let isPlayingMedia: Bool
    }

    weak var delegate: BrowserHiddenWebViewDiscardManagerDelegate?

    /// Resolves enabled/hidden-delay from the environment and `UserDefaults`. The
    /// app composition point owns picking `UserDefaults.standard` /
    /// `ProcessInfo.processInfo`; tests inject scoped seams.
    private let policy: BrowserHiddenWebViewDiscardPolicy

    private var discardTimer: DispatchSourceTimer?
    private var policyObserver: NSObjectProtocol?
    private var systemSleepObservers: [NSObjectProtocol] = []
    private var systemSleepObserverCenter: NotificationCenter?
    private var policyState: BrowserHiddenWebViewDiscardPolicy.ResolvedPolicy
    private var scheduleGeneration: UInt64 = 0

    init(policy: BrowserHiddenWebViewDiscardPolicy = BrowserHiddenWebViewDiscardPolicy()) {
        self.policy = policy
        self.policyState = policy.resolved()
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

    func blockers(for snapshot: BlockerSnapshot) -> [String] {
        var blockers: [String] = []
        if !policy.isEnabled { blockers.append("policy_disabled") }
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
        if snapshot.isPlayingMedia { blockers.append("media_playback") }
        if snapshot.preferredDeveloperToolsVisible || snapshot.isDeveloperToolsVisible {
            blockers.append("developer_tools")
        }
        if snapshot.isElementFullscreenActive { blockers.append("fullscreen") }
        if snapshot.isReactGrabActive { blockers.append("react_grab") }
        if snapshot.isVisualAutomationCaptureActive { blockers.append("visual_automation") }
        if snapshot.hasPopups { blockers.append("popup") }
        return blockers
    }

    func scheduleIfNeeded(reason: String) {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil

        guard let delegate else { return }
        guard blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty else { return }

        let observedWebViewInstanceID = delegate.hiddenWebViewDiscardWebViewInstanceID
        let generation = scheduleGeneration
        let hiddenAt = delegate.hiddenWebViewDiscardHiddenAt ?? Date()
        // Restart the countdown from the latest wake: WebKit pages reconnect and
        // re-navigate right after wake, and replacing/releasing a WKWebView in
        // that window crashed in WebPageProxy::updateActivityState
        // (https://github.com/manaflow-ai/cmux/issues/5261).
        let effectiveHiddenAt = lastSystemWakeAt.map { max(hiddenAt, $0) } ?? hiddenAt
        let elapsed = Date().timeIntervalSince(effectiveHiddenAt)
        let remaining = max(0, policy.hiddenDelay - elapsed)
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

    func cancel() {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil
    }

    /// Tracks system sleep/wake so discard countdowns armed before sleep do not
    /// fire shortly after wake. Injectable center for tests.
    func installSystemSleepObservers(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard systemSleepObservers.isEmpty else { return }
        systemSleepObserverCenter = center
        systemSleepObservers = [
            // Synchronous main-actor delivery (no Task hop): a countdown with
            // milliseconds of mach time left must see isSystemSleeping before
            // its timer can fire.
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.noteSystemWillSleep()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.noteSystemDidWake()
                }
            }
        ]
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
        scheduleIfNeeded(reason: "system_did_wake")
#if DEBUG
        cmuxDebugLog("browser.discard.wake rearmed=\(hasScheduledDiscard ? 1 : 0)")
#endif
    }

    func installPolicyObserver() {
        policyState = policy.resolved()
        guard policyObserver == nil else { return }
        policyObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePolicyDefaultsChanged()
            }
        }
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

    private func handlePolicyDefaultsChanged() {
        let nextPolicyState = policy.resolved()
        guard policyState != nextPolicyState else { return }
        policyState = nextPolicyState
        delegate?.hiddenWebViewDiscardManagerPolicyDidChange(self, reason: "policy_changed")
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
