public import AppKit
public import Foundation

/// Owns the insecure-HTTP navigation decision for one `BrowserPanel`: the
/// block/one-time-bypass policy, the pending one-time bypass host, and the
/// resolution of the user's insecure-HTTP alert choice. Pure decision logic;
/// every side effect is forwarded to the app-side ``BrowserNavigationHosting``.
///
/// `@MainActor` because the panel that owns it is `@MainActor` and every entry
/// point runs on a main-actor WebKit/omnibar turn.
@MainActor
public final class BrowserNavigationIntentCoordinator {
    /// The app-side host that performs the navigation effects. Weak because the
    /// host (`BrowserPanel`) owns this coordinator strongly and outlives it, so
    /// this is non-nil whenever a method runs.
    public weak var host: (any BrowserNavigationHosting)?

    /// The host granted a one-time insecure-HTTP bypass, consumed by the next
    /// matching navigation. Moved off the panel into this coordinator.
    public private(set) var insecureHTTPBypassHostOnce: String?

    /// - Parameter initialBypassHostOnce: The normalized host seeded with a
    ///   one-time bypass (e.g. restored from a reopened tab), or `nil`.
    public init(initialBypassHostOnce: String?) {
        self.insecureHTTPBypassHostOnce = initialBypassHostOnce
    }

    /// Routes `request` for `intent`, prompting first when the URL is blocked by
    /// the insecure-HTTP policy.
    public func requestNavigation(_ request: URLRequest, intent: BrowserInsecureHTTPNavigationIntent) {
        guard let url = request.url else { return }
        if shouldBlockInsecureHTTPNavigation(to: url) {
            host?.presentInsecureHTTPAlert(for: request, intent: intent, recordTypedNavigation: false)
            return
        }
        switch intent {
        case .currentTab:
            host?.loadRequestInCurrentTab(request, recordTypedNavigation: false)
        case .newTab:
            host?.openLinkInNewTab(request: request, bypassInsecureHTTPHostOnce: nil)
        }
    }

    /// Whether `url` should be blocked by the insecure-HTTP policy, after first
    /// consuming any matching one-time bypass.
    public func shouldBlockInsecureHTTPNavigation(to url: URL) -> Bool {
        if consumeOneTimeInsecureHTTPBypassIfNeeded(for: url) {
            return false
        }
        return BrowserInsecureHTTPSettings.shouldBlock(url)
    }

    /// Consumes the pending one-time insecure-HTTP bypass when it matches `url`.
    @discardableResult
    public func consumeOneTimeInsecureHTTPBypassIfNeeded(for url: URL) -> Bool {
        BrowserInsecureHTTPSettings.shouldConsumeOneTimeBypass(url, bypassHostOnce: &insecureHTTPBypassHostOnce)
    }

    /// Applies the user's choice from the insecure-HTTP alert: optionally persists
    /// the host to the allowlist, then opens in the default browser, proceeds in
    /// the current tab (granting a one-time bypass), opens a new tab, or cancels.
    public func resolveAlertResponse(
        _ response: NSApplication.ModalResponse,
        suppressionEnabled: Bool,
        host hostName: String,
        request: URLRequest,
        url: URL,
        intent: BrowserInsecureHTTPNavigationIntent,
        recordTypedNavigation: Bool
    ) {
        if BrowserInsecureHTTPSettings.shouldPersistAllowlistSelection(
            response: response,
            suppressionEnabled: suppressionEnabled
        ) {
            BrowserInsecureHTTPSettings.addAllowedHost(hostName)
        }
        switch response {
        case .alertFirstButtonReturn:
            host?.openURLInDefaultBrowser(url)
        case .alertSecondButtonReturn:
            switch intent {
            case .currentTab:
                insecureHTTPBypassHostOnce = hostName
                host?.loadRequestInCurrentTab(request, recordTypedNavigation: recordTypedNavigation)
            case .newTab:
                host?.openLinkInNewTab(request: request, bypassInsecureHTTPHostOnce: hostName)
            }
        default:
            return
        }
    }
}
