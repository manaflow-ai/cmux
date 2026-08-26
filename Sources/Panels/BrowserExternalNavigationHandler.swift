import AppKit
import CmuxSettings
import Foundation
import WebKit

/// Owns configured external-URL matching and the system-browser handoff.
///
/// Browser delegates and terminal routing construct this handler with the
/// same defaults and opener seam, so matching and opener-failure behavior stay
/// consistent without reaching through a static settings namespace.
@MainActor
struct BrowserExternalNavigationHandler {
    typealias OpenResult = BrowserExternalNavigationOpenResult

    private let defaults: UserDefaults
    private let openURL: @MainActor @Sendable (URL) -> Bool

    init(
        defaults: UserDefaults = .standard,
        openURL: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.defaults = defaults
        self.openURL = openURL
    }

    /// Returns whether a URL matches a configured external rule.
    func shouldOpenExternally(_ url: URL) -> Bool {
        guard !Self.isAppOwnedInternalURL(url) else {
            return false
        }
        return shouldOpenExternally(target: url.absoluteString)
    }

    /// Returns whether raw URL text matches a configured external rule.
    func shouldOpenExternally(_ rawURL: String) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        if let parsedURL = URL(string: target), Self.isAppOwnedInternalURL(parsedURL) {
            return false
        }
        return shouldOpenExternally(target: target)
    }

    private func shouldOpenExternally(target: String) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return true }
        return BrowserExternalURLPolicy(defaults: defaults).matches(target)
    }

    /// Returns whether a user-activated main-frame navigation should be external.
    func shouldOpenExternally(
        _ url: URL,
        navigationType: WKNavigationType,
        targetFrameIsMain: Bool?
    ) -> Bool {
        guard navigationType == .linkActivated,
              targetFrameIsMain != false,
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
        guard shouldOpenExternally(url) else { return .notConfigured }
        guard openURL(url) else { return .failed }
        onOpened()
        return .opened
    }

    /// Opens a matching user-activated navigation through the injected opener.
    @discardableResult
    func openConfiguredExternallyIfNeeded(
        _ url: URL,
        navigationType: WKNavigationType,
        targetFrameIsMain: Bool?,
        onOpened: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        if case .opened = openConfiguredExternallyResult(
            url,
            navigationType: navigationType,
            targetFrameIsMain: targetFrameIsMain,
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
        onOpened: @escaping @MainActor () -> Void = {}
    ) -> OpenResult {
        guard shouldOpenExternally(
            url,
            navigationType: navigationType,
            targetFrameIsMain: targetFrameIsMain
        ) else {
            return .notConfigured
        }
        guard openURL(url) else { return .failed }
        onOpened()
        return .opened
    }
}
