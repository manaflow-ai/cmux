import Foundation
import Testing
@testable import CmuxBrowser

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/15069:
/// by default a hidden pane keeps its page until hidden web content exceeds
/// the memory budget, like a Chrome tab discard. A fixed hidden-time timer
/// must be opt-in, so an idle pane hidden past the delay is not discarded
/// just because time passed.
@MainActor
struct BrowserHiddenWebViewMemoryBudgetTests {
    @Test("The default policy does not discard an idle hidden pane on a timer")
    func defaultPolicyDoesNotDiscardOnTimer() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        let delegate = DiscardDelegate(hiddenAt: Date().addingTimeInterval(-3600))
        manager.delegate = delegate

        manager.scheduleIfNeeded(reason: "test.hidden")

        #expect(delegate.discardRequestCount == 0)
        #expect(!manager.hasScheduledDiscard)
    }

    @Test("Timer mode still discards a pane hidden past the delay")
    func timerModeDiscardsPaneHiddenPastDelay() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        defaults.set("timer", forKey: BrowserHiddenWebViewDiscardPolicy.modeKey)
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        let delegate = DiscardDelegate(hiddenAt: Date().addingTimeInterval(-3600))
        manager.delegate = delegate

        manager.scheduleIfNeeded(reason: "test.hidden")

        #expect(delegate.discardRequests == ["test.hidden"])
    }

    @Test("Timer mode arms a countdown for a pane hidden less than the delay")
    func timerModeArmsCountdownWithinDelay() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        defaults.set("timer", forKey: BrowserHiddenWebViewDiscardPolicy.modeKey)
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        let delegate = DiscardDelegate(hiddenAt: Date())
        manager.delegate = delegate

        manager.scheduleIfNeeded(reason: "test.hidden")
        defer { manager.cancel() }

        #expect(manager.hasScheduledDiscard)
        #expect(delegate.discardRequests.isEmpty)
    }

    @Test("The budget may discard a pane only once it has been hidden for the delay")
    func budgetEligibilityRequiresHiddenDelay() {
        let now = Date()
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        let delegate = DiscardDelegate(hiddenAt: now.addingTimeInterval(-60))
        manager.delegate = delegate
        #expect(!manager.isEligibleForMemoryBudgetDiscard(now: now))

        delegate.hiddenAt = now.addingTimeInterval(-BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay)
        #expect(manager.isEligibleForMemoryBudgetDiscard(now: now))

        delegate.hiddenAt = nil
        #expect(!manager.isEligibleForMemoryBudgetDiscard(now: now))
    }

    @Test("The budget never discards a pane a blocker protects")
    func budgetEligibilityRespectsBlockers() {
        let now = Date()
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        let delegate = DiscardDelegate(hiddenAt: now.addingTimeInterval(-3600))
        delegate.snapshot = DiscardDelegate.makeSnapshot(isPlayingMedia: true)
        manager.delegate = delegate

        #expect(!manager.isEligibleForMemoryBudgetDiscard(now: now))
        #expect(!manager.requestMemoryBudgetDiscard(now: now))
        #expect(delegate.discardRequests.isEmpty)
    }

    @Test("The budget waits the delay again after the system wakes")
    func budgetEligibilityRestartsAfterWake() {
        let now = Date()
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        let delegate = DiscardDelegate(hiddenAt: now.addingTimeInterval(-3600))
        manager.delegate = delegate

        manager.noteSystemDidWake(now: now.addingTimeInterval(-60))

        #expect(!manager.isEligibleForMemoryBudgetDiscard(now: now))
    }

    @Test("A budget discard reports the memory budget reason")
    func budgetDiscardReportsReason() {
        let now = Date()
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        let delegate = DiscardDelegate(hiddenAt: now.addingTimeInterval(-3600))
        manager.delegate = delegate

        #expect(manager.requestMemoryBudgetDiscard(now: now))
        #expect(delegate.discardRequests == [BrowserHiddenWebViewDiscardManager.memoryBudgetReason])
    }

    @Test("Mode and budget settings fall back to their defaults when unset or invalid")
    func policyResolvesModeAndBudget() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        #expect(BrowserHiddenWebViewDiscardPolicy.mode(defaults: defaults) == .memoryBudget)
        #expect(BrowserHiddenWebViewDiscardPolicy.memoryBudgetMB(defaults: defaults) == 2048)

        defaults.set("timer", forKey: BrowserHiddenWebViewDiscardPolicy.modeKey)
        defaults.set(4096, forKey: BrowserHiddenWebViewDiscardPolicy.memoryBudgetKey)
        #expect(BrowserHiddenWebViewDiscardPolicy.mode(defaults: defaults) == .timer)
        #expect(BrowserHiddenWebViewDiscardPolicy.memoryBudgetMB(defaults: defaults) == 4096)

        defaults.set("sometimes", forKey: BrowserHiddenWebViewDiscardPolicy.modeKey)
        defaults.set(100, forKey: BrowserHiddenWebViewDiscardPolicy.memoryBudgetKey)
        #expect(BrowserHiddenWebViewDiscardPolicy.mode(defaults: defaults) == .memoryBudget)
        #expect(BrowserHiddenWebViewDiscardPolicy.memoryBudgetMB(defaults: defaults) == 2048)
    }

    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "cmux-hidden-webview-budget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}

@MainActor
private final class DiscardDelegate: BrowserHiddenWebViewDiscardManagerDelegate {
    var snapshot = makeSnapshot()
    var hiddenAt: Date?
    let webViewInstanceID = UUID()
    private(set) var discardRequests: [String] = []
    var discardRequestCount: Int { discardRequests.count }

    init(hiddenAt: Date?) {
        self.hiddenAt = hiddenAt
    }

    static func makeSnapshot(isPlayingMedia: Bool = false) -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
        BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
            isClosing: false,
            isVisibleInUI: false,
            shouldRenderWebView: true,
            hasPendingRemoteNavigation: false,
            hasCurrentURL: true,
            isLoading: false,
            webViewIsLoading: false,
            hasActiveMainFrameProvisionalNavigation: false,
            isDownloading: false,
            activeDownloadCount: 0,
            preferredDeveloperToolsVisible: false,
            isDeveloperToolsVisible: false,
            isElementFullscreenActive: false,
            isReactGrabActive: false,
            isVisualAutomationCaptureActive: false,
            hasPopups: false,
            isCapturingMedia: false,
            isPlayingMedia: isPlayingMedia
        )
    }

    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot { snapshot }
    var hiddenWebViewDiscardHiddenAt: Date? { hiddenAt }
    var hiddenWebViewDiscardWebViewInstanceID: UUID { webViewInstanceID }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        discardRequests.append(reason)
    }

    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {}
}
