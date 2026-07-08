import Foundation
import WebKit

extension BrowserPanel {
    func shouldTreatCommitAsDiscardedRestoreCommit(from webView: WKWebView) -> Bool {
        guard navigationDelegate?.activeErrorPageDisplayURL == nil else { return false }
        guard let committedURL = webView.url else { return false }
        return !Self.isAboutBlankURL(committedURL)
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
