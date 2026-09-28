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
        let defaults = makeDefaults()
        defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        let delegate = DiscardDelegate(hiddenAt: Date().addingTimeInterval(-3600))
        manager.delegate = delegate

        manager.scheduleIfNeeded(reason: "test.hidden")

        #expect(delegate.discardRequestCount == 0)
        #expect(!manager.hasScheduledDiscard)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "cmux-hidden-webview-budget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class DiscardDelegate: BrowserHiddenWebViewDiscardManagerDelegate {
    var snapshot = BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
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
        isPlayingMedia: false
    )
    var hiddenAt: Date?
    let webViewInstanceID = UUID()
    private(set) var discardRequestCount = 0

    init(hiddenAt: Date?) {
        self.hiddenAt = hiddenAt
    }

    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot { snapshot }
    var hiddenWebViewDiscardHiddenAt: Date? { hiddenAt }
    var hiddenWebViewDiscardWebViewInstanceID: UUID { webViewInstanceID }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        discardRequestCount += 1
    }

    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {}
}
