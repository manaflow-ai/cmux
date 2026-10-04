import Foundation
import Testing
@testable import CmuxBrowser

/// Coverage for https://github.com/manaflow-ai/cmux/issues/15069: typed input
/// a restore cannot replay, Picture in Picture and the per-pane keep-active pin
/// each keep a hidden pane's page. System memory pressure overrides only the
/// typed input, which a restore loses but which is not live activity.
@MainActor
struct BrowserHiddenWebViewDiscardBlockerTests {
    @Test("Unrestorable typed input blocks a budget discard but not a pressure discard")
    func unrestorableInputYieldsToPressure() {
        let now = Date()
        let (manager, delegate, cleanup) = makeManager(hiddenAt: now.addingTimeInterval(-3600))
        defer { cleanup() }
        delegate.snapshot = BlockerDelegate.makeSnapshot(hasUnrestorableFormInput: true)

        #expect(manager.blockers(for: delegate.snapshot, now: now) == ["form_input"])
        #expect(!manager.requestMemoryBudgetDiscard(now: now))
        #expect(delegate.discardRequests.isEmpty)

        #expect(manager.blockers(for: delegate.snapshot, now: now, urgency: .systemMemoryPressure).isEmpty)
        let pressureReason = BrowserHiddenWebViewDiscardManager.systemMemoryPressureReason
        #expect(manager.requestImmediateDiscardIfSafe(reason: pressureReason, now: now))
        #expect(delegate.discardRequests == [pressureReason])
    }

    @Test("Picture in Picture blocks both budget and pressure discards")
    func pictureInPictureBlocksEveryDiscard() {
        let now = Date()
        let (manager, delegate, cleanup) = makeManager(hiddenAt: now.addingTimeInterval(-3600))
        defer { cleanup() }
        delegate.snapshot = BlockerDelegate.makeSnapshot(isPictureInPictureActive: true)

        #expect(manager.blockers(for: delegate.snapshot, now: now) == ["picture_in_picture"])
        #expect(!manager.requestMemoryBudgetDiscard(now: now))
        let pressureReason = BrowserHiddenWebViewDiscardManager.systemMemoryPressureReason
        #expect(!manager.requestImmediateDiscardIfSafe(reason: pressureReason, now: now))
        #expect(delegate.discardRequests.isEmpty)
    }

    @Test("A keep-active pin blocks both budget and pressure discards")
    func keepActivePinBlocksEveryDiscard() {
        let now = Date()
        let (manager, delegate, cleanup) = makeManager(hiddenAt: now.addingTimeInterval(-3600))
        defer { cleanup() }
        manager.keepsPageActive = true

        #expect(manager.blockers(for: delegate.snapshot, now: now) == ["keep_active"])
        #expect(!manager.isEligibleForMemoryBudgetDiscard(now: now))
        #expect(!manager.requestMemoryBudgetDiscard(now: now))
        let pressureReason = BrowserHiddenWebViewDiscardManager.systemMemoryPressureReason
        #expect(!manager.requestImmediateDiscardIfSafe(reason: pressureReason, now: now))
        #expect(delegate.discardRequests.isEmpty)

        manager.keepsPageActive = false
        #expect(manager.requestMemoryBudgetDiscard(now: now))
        #expect(delegate.discardRequests == [BrowserHiddenWebViewDiscardManager.memoryBudgetReason])
    }

    @Test("Toggling the keep-active pin re-evaluates the pane's discard policy once per change")
    func keepActivePinNotifiesPolicyChange() {
        let (manager, delegate, cleanup) = makeManager(hiddenAt: Date())
        defer { cleanup() }

        manager.keepsPageActive = true
        manager.keepsPageActive = true
        manager.keepsPageActive = false

        #expect(delegate.policyChanges == ["keep_active_changed", "keep_active_changed"])
    }

    @Test("Pressure still keeps a pane that is playing media or capturing it")
    func pressureRespectsLiveMedia() {
        let now = Date()
        let (manager, _, cleanup) = makeManager(hiddenAt: now.addingTimeInterval(-3600))
        defer { cleanup() }

        let playing = BlockerDelegate.makeSnapshot(isPlayingMedia: true)
        #expect(manager.blockers(for: playing, now: now, urgency: .systemMemoryPressure) == ["media_playback"])
        let capturing = BlockerDelegate.makeSnapshot(isCapturingMedia: true)
        #expect(manager.blockers(for: capturing, now: now, urgency: .systemMemoryPressure) == ["media_capture"])
    }

    @Test("Only the system memory pressure reason is urgent")
    func urgencyFromReason() {
        #expect(BrowserHiddenWebViewDiscardUrgency(reason: BrowserHiddenWebViewDiscardManager.systemMemoryPressureReason) == .systemMemoryPressure)
        #expect(BrowserHiddenWebViewDiscardUrgency(reason: BrowserHiddenWebViewDiscardManager.memoryBudgetReason) == .routine)
        #expect(BrowserHiddenWebViewDiscardUrgency(reason: "hidden_timer") == .routine)
    }

    private func makeManager(hiddenAt: Date?) -> (BrowserHiddenWebViewDiscardManager, BlockerDelegate, () -> Void) {
        let suiteName = "cmux-hidden-webview-blockers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        let delegate = BlockerDelegate(hiddenAt: hiddenAt)
        manager.delegate = delegate
        return (manager, delegate, { defaults.removePersistentDomain(forName: suiteName) })
    }
}

/// Coverage for how the media-playback hook's per-frame reports fold into the
/// page's playback and Picture in Picture state.
struct BrowserMediaPlaybackFramesTests {
    @Test("Picture in Picture stays active while its video is paused")
    func pausedPictureInPictureStaysActive() {
        var frames = BrowserMediaPlaybackFrames()
        frames.apply(BrowserMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: true, isPictureInPicture: true))
        #expect(frames.isPlaying && frames.isAudible && frames.isPictureInPictureActive)

        frames.apply(BrowserMediaPlaybackReport(frameID: "main", isPlaying: false, isAudible: true, isPictureInPicture: true))
        #expect(!frames.isPlaying)
        #expect(!frames.isAudible)
        #expect(frames.isPictureInPictureActive)

        frames.apply(BrowserMediaPlaybackReport(frameID: "main", isPlaying: false, isAudible: false))
        #expect(!frames.isPictureInPictureActive)
    }

    @Test("A frame's report replaces only that frame's state")
    func framesAggregateIndependently() {
        var frames = BrowserMediaPlaybackFrames()
        frames.apply(BrowserMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: false))
        frames.apply(BrowserMediaPlaybackReport(frameID: "iframe", isPlaying: false, isAudible: false, isPictureInPicture: true))
        #expect(frames.isPlaying)
        #expect(!frames.isAudible)
        #expect(frames.isPictureInPictureActive)

        frames.apply(BrowserMediaPlaybackReport(frameID: "main", isPlaying: false, isAudible: false))
        #expect(!frames.isPlaying)
        #expect(frames.isPictureInPictureActive)
    }
}

@MainActor
private final class BlockerDelegate: BrowserHiddenWebViewDiscardManagerDelegate {
    var snapshot = makeSnapshot()
    var hiddenAt: Date?
    let webViewInstanceID = UUID()
    private(set) var discardRequests: [String] = []
    private(set) var policyChanges: [String] = []

    init(hiddenAt: Date?) {
        self.hiddenAt = hiddenAt
    }

    static func makeSnapshot(
        isCapturingMedia: Bool = false,
        isPlayingMedia: Bool = false,
        isPictureInPictureActive: Bool = false,
        hasUnrestorableFormInput: Bool = false
    ) -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
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
            isCapturingMedia: isCapturingMedia,
            isPlayingMedia: isPlayingMedia,
            isPictureInPictureActive: isPictureInPictureActive,
            hasUnrestorableFormInput: hasUnrestorableFormInput
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
    ) {
        policyChanges.append(reason)
    }
}
