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
        guard url.scheme?.lowercased() != AuthEnvironment.callbackScheme.lowercased(),
              !BrowserAuthCallbackNavigationPolicy.shouldBlockExternalNavigation(url) else {
            return false
        }
        return shouldOpenExternally(url.absoluteString)
    }

    /// Returns whether raw URL text matches a configured external rule.
    func shouldOpenExternally(_ rawURL: String) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return true }
        return BrowserExternalURLPolicy(defaults: defaults).matches(target)
    }

    /// Returns whether a user-activated main-frame navigation should be external.
    func shouldOpenExternally(
        _ url: URL,
        navigationType: WKNavigationType,
        targetFrameIsMain: Bool?
    ) -> Bool {
        guard !BrowserAuthCallbackNavigationPolicy.shouldBlockExternalNavigation(url) else {
            return false
        }
        guard navigationType == .linkActivated,
              targetFrameIsMain != false,
              url.scheme?.lowercased() != AuthEnvironment.callbackScheme.lowercased() else {
            return false
        }
        return shouldOpenExternally(url)
    }

    /// Opens a matching URL through the injected system-browser opener.
    @discardableResult
    func openConfiguredExternallyIfNeeded(
        _ url: URL,
        onOpened: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard shouldOpenExternally(url), openURL(url) else { return false }
        onOpened()
        return true
    }

    /// Opens a matching user-activated navigation through the injected opener.
    @discardableResult
    func openConfiguredExternallyIfNeeded(
        _ url: URL,
        navigationType: WKNavigationType,
        targetFrameIsMain: Bool?,
        onOpened: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard shouldOpenExternally(
            url,
            navigationType: navigationType,
            targetFrameIsMain: targetFrameIsMain
        ), openURL(url) else {
            return false
        }
        onOpened()
        return true
    }
}
