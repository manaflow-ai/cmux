import AppKit
import CmuxCore
import CmuxSettings
import CmuxTestSupport
import Foundation
import WebKit

/// Owns configured external-URL matching and the system-browser handoff.
///
/// Browser delegates and terminal routing construct this handler with the
/// same defaults and opener seam, so matching and opener-failure behavior stay
/// consistent without reaching through a static settings namespace. The
/// compiled policy is retained and refreshed only when its stored rule value
/// changes, keeping repeated link actions bounded on the main actor.
@MainActor
struct BrowserExternalNavigationHandler {
    typealias OpenResult = BrowserExternalNavigationOpenResult

    private let defaults: UserDefaults
    private let openURL: @MainActor @Sendable (URL) -> Bool
    private let policyCache: BrowserExternalURLPolicyCache

    init(
        defaults: UserDefaults = .standard,
        openURL: @escaping @MainActor @Sendable (URL) -> Bool = Self.openInSystemBrowser
    ) {
        self.defaults = defaults
        self.openURL = openURL
        self.policyCache = BrowserExternalURLPolicyCache(defaults: defaults)
    }

    /// The default opener. UI tests observe external-open routing through the
    /// capture sink; a configured sink intercepts the open so CI never
    /// launches a real browser.
    @MainActor
    private static func openInSystemBrowser(_ url: URL) -> Bool {
#if DEBUG
        if UITestCaptureSink().appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_EXTERNAL_OPEN_PATH",
            line: "externalOpen \(url.absoluteString)"
        ) {
            return true
        }
#endif
        return NSWorkspace.shared.open(url)
    }

    /// Returns whether a URL matches a configured external rule.
    func shouldOpenExternally(_ url: URL) -> Bool {
        let externalURL = canonicalURL(for: url)
        guard !Self.isAppOwnedInternalURL(externalURL) else {
            return false
        }
        return shouldOpenExternally(target: externalURL.absoluteString)
    }

    /// Returns whether raw URL text matches a configured external rule.
    func shouldOpenExternally(_ rawURL: String) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        if let parsedURL = URL(string: target) {
            let externalURL = canonicalURL(for: parsedURL)
            guard !Self.isAppOwnedInternalURL(externalURL) else { return false }
            return shouldOpenExternally(target: externalURL.absoluteString)
        }
        return shouldOpenExternally(target: target)
    }

    private func shouldOpenExternally(target: String) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return true }
        return policyCache.currentPolicy().matches(target)
    }

    /// True when a link the user chose outside a web view (a sidebar
    /// pull-request or port link) should bypass the embedded browser and go
    /// to the system browser. Restricted to web schemes; other schemes have
    /// their own external-open routing.
    func linkEscapesToSystemBrowser(_ url: URL) -> Bool {
        guard Self.isWebNavigationURL(url) else { return false }
        return shouldOpenExternally(url)
    }

    /// Returns whether a user-activated main-frame navigation should be external.
    ///
    /// Downloads keep the download flow. WebKit reports a script calling
    /// `click()` on an anchor as `.linkActivated`, the same as a real click,
    /// so the rules on their own would let a page hand itself a system-browser
    /// open at a moment of its choosing; requiring an AppKit event in flight
    /// makes the page ride a click the user actually made. It is a bound
    /// rather than a proof — `NSApp.currentEvent` says an event is being
    /// dispatched, not that this navigation is the thing the user asked for.
    func shouldOpenExternally(
        _ url: URL,
        navigationType: WKNavigationType,
        targetFrameIsMain: Bool?,
        shouldPerformDownload: Bool = false,
        hasUserActivation: Bool = browserNavigationHasSimpleUserActivation()
    ) -> Bool {
        guard navigationType == .linkActivated,
              targetFrameIsMain != false,
              !shouldPerformDownload,
              hasUserActivation,
              Self.isWebNavigationURL(url),
              !Self.isAppOwnedInternalURL(url) else {
            return false
        }
        return shouldOpenExternally(url)
    }

    /// Rule-based browser handoffs are limited to web links. Other schemes
    /// retain the browser's existing confirmation/fallback policy instead of
    /// letting a user rule silently launch an arbitrary registered app.
    private static func isWebNavigationURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return true
        default: return false
        }
    }

    private static func isAppOwnedInternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == AuthEnvironment.callbackScheme.lowercased() {
            return true
        }
        if BrowserURLAllowlistPolicy.trustedInternalSchemes.contains(scheme) {
            return true
        }
        return BrowserAuthCallbackNavigationPolicy.shouldBlockExternalNavigation(url)
    }

    /// Maps the browser-only remote loopback alias back to its user-visible URL.
    private func canonicalURL(for url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host,
              let displayHost = RemoteLoopbackProxyAlias.localhostFamilyHost(
                  forAliasHost: host,
                  aliasHost: RemoteLoopbackProxyAlias.aliasHost
              ) else {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = displayHost
        return components?.url ?? url
    }

    /// Opens a matching URL through the injected system-browser opener.
    @discardableResult
    func openConfiguredExternallyIfNeeded(
        _ url: URL,
        onOpened: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        if case .opened = openConfiguredExternallyResult(url, onOpened: onOpened) {
            return true
        }
        return false
    }

    /// Attempts a configured external open and distinguishes no match from an
    /// opener failure so callers can avoid silently falling back in-app.
    @discardableResult
    func openConfiguredExternallyResult(
        _ url: URL,
        onOpened: @escaping @MainActor () -> Void = {}
    ) -> OpenResult {
        let externalURL = canonicalURL(for: url)
        guard shouldOpenExternally(externalURL) else { return .notConfigured }
        guard openURL(externalURL) else { return .failed }
        onOpened()
        return .opened
    }

    /// Opens a matching user-activated navigation through the injected opener.
    @discardableResult
    func openConfiguredExternallyIfNeeded(
        _ url: URL,
        navigationType: WKNavigationType,
        targetFrameIsMain: Bool?,
        shouldPerformDownload: Bool = false,
        hasUserActivation: Bool = browserNavigationHasSimpleUserActivation(),
        onOpened: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        if case .opened = openConfiguredExternallyResult(
            url,
            navigationType: navigationType,
            targetFrameIsMain: targetFrameIsMain,
            shouldPerformDownload: shouldPerformDownload,
            hasUserActivation: hasUserActivation,
            onOpened: onOpened
        ) {
            return true
        }
        return false
    }

    /// Attempts a user-activated external open while preserving opener status.
    @discardableResult
    func openConfiguredExternallyResult(
        _ url: URL,
        navigationType: WKNavigationType,
        targetFrameIsMain: Bool?,
        shouldPerformDownload: Bool = false,
        hasUserActivation: Bool = browserNavigationHasSimpleUserActivation(),
        onOpened: @escaping @MainActor () -> Void = {}
    ) -> OpenResult {
        let externalURL = canonicalURL(for: url)
        guard shouldOpenExternally(
            externalURL,
            navigationType: navigationType,
            targetFrameIsMain: targetFrameIsMain,
            shouldPerformDownload: shouldPerformDownload,
            hasUserActivation: hasUserActivation
        ) else {
            return .notConfigured
        }
        guard openURL(externalURL) else { return .failed }
        onOpened()
        return .opened
    }
}
