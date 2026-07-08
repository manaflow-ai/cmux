import Foundation
import WebKit

extension BrowserPanel {
    func shouldTreatCommitAsDiscardedRestoreCommit(from webView: WKWebView) -> Bool {
        guard navigationDelegate?.activeErrorPageDisplayURL == nil else { return false }
        guard let committedURL = webView.url else { return false }
        return !Self.isAboutBlankURL(committedURL)
    }

    func noteDiscardedWebViewRestoreNavigationStarted() {
        if hiddenWebViewDiscardManager.isDiscardedForMemory {
            // Each restore attempt tracks its own commit. Without this reset, a
            // previous attempt's error-page commit would satisfy the stall
            // detector forever and a silently stalled retry could never re-arm.
            hasCommittedDocumentSinceWebViewReplacement = false
        }
        hiddenWebViewDiscardManager.noteRestoreNavigationStarted(reason: "navigation")
        refreshWebViewLifecycleState()
    }

    func noteDiscardedWebViewRestoreNavigationCommitted(reason: String = "navigation_commit") {
        guard hiddenWebViewDiscardManager.noteRestoreNavigationCommitted(reason: reason) else {
            return
        }
        pendingDiscardRestoreNavigation = nil
        refreshWebViewLifecycleState()
    }

    func noteDiscardedWebViewRestoreNavigationDidNotCommit(reason: String) {
        hiddenWebViewDiscardManager.noteRestoreNavigationDidNotCommit(reason: reason)
        pendingDiscardRestoreNavigation = nil
        refreshWebViewLifecycleState()
    }

    /// Whether a WebKit failure/cancel callback belongs to the navigation the
    /// discard-restore bookkeeping is tracking. WebKit can deliver an older
    /// provisional load's cancellation after a newer attempt has already
    /// started; clearing the pending state for that stale callback would let a
    /// visibility touch hijack the in-flight navigation with a restore reload.
    /// A nil callback navigation or no tracked navigation matches conservatively.
    func isDiscardRestoreBookkeepingNavigation(_ navigation: WKNavigation?) -> Bool {
        guard let tracked = pendingDiscardRestoreNavigation else { return true }
        guard let navigation else { return true }
        return navigation === tracked
    }

    /// Restore touch for a possibly-discarded pane: detects stalled restore
    /// attempts, honors an explicit user Stop, restores through the discard
    /// manager, and falls back to blank-shell healing.
    @discardableResult
    func restoreDiscardedWebViewIfNeeded(
        reason: String,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        allowBlankShellHeal: Bool = true,
        forceRestartPendingRestore: Bool = false
    ) -> Bool {
        if Self.isRestoreStalled(
            isRestoreNavigationPending: hiddenWebViewDiscardManager.isRestoreNavigationPending,
            isWebViewLoading: webView.isLoading,
            isMainFrameProvisionalNavigationActive: isMainFrameProvisionalNavigationActive,
            hasPendingRemoteNavigation: hasPendingRemoteNavigation,
            hasCommittedDocument: hasCommittedDocumentSinceWebViewReplacement
        ) {
            hiddenWebViewDiscardManager.noteRestoreNavigationDidNotCommit(reason: "\(reason).stalled")
            refreshWebViewLifecycleState()
        }

        if forceRestartPendingRestore {
            userStoppedLoadSinceWebViewReplacement = false
        }
        // Stop is sticky for discarded restores too: routine visibility touches
        // must not restart a stopped load; explicit reload is the override.
        guard !userStoppedLoadSinceWebViewReplacement else { return false }

        let restoreURL = restoredHistoryCurrentURL ?? currentURL
        guard let restoreURL, !Self.isAboutBlankURL(restoreURL) else {
            return reactivateDiscardedPaneWithoutRestorableURL(reason: reason)
        }

        if hiddenWebViewDiscardManager.restoreIfNeeded(reason: reason, force: forceRestartPendingRestore, performRestore: {
            shouldRenderWebView = true
            navigateWithoutInsecureHTTPPrompt(
                to: restoreURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true,
                cachePolicy: cachePolicy
            )
        }) {
            return true
        }

        guard allowBlankShellHeal else { return false }
        return healBlankRestoredWebViewIfNeeded(reason: reason, cachePolicy: cachePolicy)
    }

    /// Re-navigates a rendered-but-empty web view (for example after a failed
    /// discard restore whose state was already consumed) back to its intent URL.
    @discardableResult
    private func healBlankRestoredWebViewIfNeeded(
        reason _: String,
        cachePolicy: URLRequest.CachePolicy
    ) -> Bool {
        let intentURL = restoredHistoryCurrentURL ?? currentURL
        let isNavigationBlockedPendingConsent = intentURL.map { browserShouldBlockInsecureHTTPURL($0) } ?? false
        guard Self.shouldHealBlankShell(
            shouldRenderWebView: shouldRenderWebView,
            isClosing: isClosingWebViewLifecycle,
            hasPendingRemoteNavigation: hasPendingRemoteNavigation,
            isWebViewLoading: webView.isLoading,
            isMainFrameProvisionalNavigationActive: isMainFrameProvisionalNavigationActive,
            hasCommittedDocument: hasCommittedDocumentSinceWebViewReplacement,
            isNavigationBlockedPendingConsent: isNavigationBlockedPendingConsent,
            hasRecoverableWebContentTermination: hasRecoverableWebContentTermination,
            userStoppedLoad: userStoppedLoadSinceWebViewReplacement,
            intentURL: intentURL
        ) else {
            return false
        }
        guard let intentURL else { return false }
        navigateWithoutInsecureHTTPPrompt(
            to: intentURL,
            recordTypedNavigation: false,
            preserveRestoredSessionHistory: true,
            cachePolicy: cachePolicy
        )
        return true
    }

    /// Restore fallback for a discarded pane with no restorable document (nil
    /// or about:blank restore URL): navigating would wait on a commit that
    /// ``shouldTreatCommitAsDiscardedRestoreCommit(from:)`` ignores, leaving the
    /// manager pending forever, so reactivate in place instead.
    func reactivateDiscardedPaneWithoutRestorableURL(reason: String) -> Bool {
        guard reactivateDiscardedWebViewWithoutNavigation(reason: "\(reason).no_restore_url") else {
            return false
        }
        refreshNavigationAvailability()
        refreshWebViewLifecycleState()
        return true
    }

    /// ISO8601DateFormatter is documented thread-safe; cached so the polled
    /// lifecycle-payload path stays allocation-free.
    private nonisolated(unsafe) static let webViewLifecycleTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated static func webViewLifecycleTimestamp(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return webViewLifecycleTimestampFormatter.string(from: date)
    }

    nonisolated static func webViewHiddenDurationMilliseconds(
        hiddenAt: Date?,
        visible: Bool,
        now: Date
    ) -> Any {
        guard !visible, let hiddenAt else { return NSNull() }
        return max(0, Int((now.timeIntervalSince(hiddenAt) * 1000.0).rounded()))
    }

    nonisolated static func isAboutBlankURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.caseInsensitiveCompare("about:blank") == .orderedSame
    }

    nonisolated static func shouldHealBlankShell(
        shouldRenderWebView: Bool,
        isClosing: Bool,
        hasPendingRemoteNavigation: Bool,
        isWebViewLoading: Bool,
        isMainFrameProvisionalNavigationActive: Bool,
        hasCommittedDocument: Bool,
        isNavigationBlockedPendingConsent: Bool,
        hasRecoverableWebContentTermination: Bool,
        userStoppedLoad: Bool,
        intentURL: URL?
    ) -> Bool {
        guard shouldRenderWebView else { return false }
        guard !isClosing else { return false }
        guard !hasPendingRemoteNavigation else { return false }
        guard !isWebViewLoading else { return false }
        guard !isMainFrameProvisionalNavigationActive else { return false }
        guard !hasCommittedDocument else { return false }
        guard !isNavigationBlockedPendingConsent else { return false }
        // A crashed WebContent process waits for the user's explicit Reload;
        // auto-healing here would bypass that gate and can re-enter the crash.
        guard !hasRecoverableWebContentTermination else { return false }
        // A load the user explicitly stopped before first commit must stay
        // stopped; healing on reveal would silently undo the Stop.
        guard !userStoppedLoad else { return false }
        guard let intentURL else { return false }
        return !isAboutBlankURL(intentURL)
    }

    nonisolated static func isRestoreStalled(
        isRestoreNavigationPending: Bool,
        isWebViewLoading: Bool,
        isMainFrameProvisionalNavigationActive: Bool,
        hasPendingRemoteNavigation: Bool,
        hasCommittedDocument: Bool
    ) -> Bool {
        guard isRestoreNavigationPending else { return false }
        guard !isWebViewLoading else { return false }
        guard !isMainFrameProvisionalNavigationActive else { return false }
        guard !hasPendingRemoteNavigation else { return false }
        return !hasCommittedDocument
    }
}

extension BrowserPanel {
    /// Whether browser native/SwiftUI fills should draw over the window root
    /// backdrop. Mirrors terminal/markdown panel background decisions.
    static func drawsConfiguredWebViewBackground(
        isBlankPage: Bool,
        usesTransparentBackground: Bool = false
    ) -> Bool {
        drawsWebViewBackground(
            isBlankPage: isBlankPage,
            usesTransparentBackground: usesTransparentBackground,
            opacity: GhosttyApp.shared.defaultBackgroundOpacity,
            usesGhosttyGlassStyle: GhosttyApp.shared.defaultBackgroundBlur.isMacOSGlassStyle,
            usesTransparentWindow: WindowBackgroundComposition.policy
                .shouldUseTransparentBackgroundWindow(glassEffectAvailable: false)
        )
    }

    nonisolated static func isBlankBrowserPageURL(_ url: URL?) -> Bool {
        guard let url else { return true }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.caseInsensitiveCompare("about:blank") == .orderedSame
    }

    nonisolated static func isBlankBrowserPage(
        liveURL: URL?,
        currentURL: URL?,
        pendingNavigationURL: URL?,
        isMainFrameProvisionalNavigationActive: Bool
    ) -> Bool {
        if isMainFrameProvisionalNavigationActive,
           !isBlankBrowserPageURL(pendingNavigationURL) {
            return false
        }
        if !isBlankBrowserPageURL(pendingNavigationURL),
           isBlankBrowserPageURL(liveURL),
           isBlankBrowserPageURL(currentURL) {
            return false
        }
        return isBlankBrowserPageURL(liveURL) && isBlankBrowserPageURL(currentURL)
    }

    nonisolated static func drawsWebViewBackground(
        isBlankPage: Bool,
        usesTransparentBackground: Bool = false,
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        if usesTransparentBackground {
            return drawsWebViewBackground(
                opacity: opacity,
                usesGhosttyGlassStyle: usesGhosttyGlassStyle,
                usesTransparentWindow: usesTransparentWindow
            )
        }
        guard isBlankPage else { return true }
        return drawsWebViewBackground(
            opacity: opacity,
            usesGhosttyGlassStyle: usesGhosttyGlassStyle,
            usesTransparentWindow: usesTransparentWindow
        )
    }

    nonisolated static func drawsWebViewBackground(
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        !PanelAppearance.shouldUseClearContentBackground(
            opacity: opacity,
            usesGhosttyGlassStyle: usesGhosttyGlassStyle,
            usesTransparentWindow: usesTransparentWindow
        )
    }
}
