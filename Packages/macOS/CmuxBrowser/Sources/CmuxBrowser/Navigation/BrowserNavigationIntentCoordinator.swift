public import AppKit
public import Foundation

// CmuxSettings owns BrowserSearchSettingsStore, the search-engine configuration
// navigateSmart(_:) consults to turn non-URL input into a search request.
import CmuxSettings

/// Owns the navigation decision and dispatch for one `BrowserPanel`: the
/// insecure-HTTP block/one-time-bypass policy, the pending one-time bypass host,
/// the resolution of the user's insecure-HTTP alert choice, the remote-proxy
/// navigation queue, and smart URL/search dispatch. Pure decision logic; every
/// side effect is forwarded to the app-side ``BrowserNavigationHosting``.
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

    /// A navigation deferred until a remote-workspace proxy endpoint becomes
    /// available, replayed by ``resumePendingRemoteNavigationIfNeeded()``. Moved
    /// off the panel into this coordinator.
    public private(set) var pendingRemoteNavigation: PendingRemoteNavigation?

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

    /// Navigates to `url`, prompting first when the insecure-HTTP policy blocks it.
    public func navigate(to url: URL, recordTypedNavigation: Bool = false) {
        let request = URLRequest(url: url)
        if shouldBlockInsecureHTTPNavigation(to: url) {
            host?.presentInsecureHTTPAlert(for: request, intent: .currentTab, recordTypedNavigation: recordTypedNavigation)
            return
        }
        navigateWithoutInsecureHTTPPrompt(request: request, recordTypedNavigation: recordTypedNavigation)
    }

    /// Builds a request for `url` and routes it past the insecure-HTTP prompt.
    public func navigateWithoutInsecureHTTPPrompt(
        to url: URL,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool = false,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) {
        let request = URLRequest(url: url, cachePolicy: cachePolicy)
        navigateWithoutInsecureHTTPPrompt(
            request: request,
            recordTypedNavigation: recordTypedNavigation,
            preserveRestoredSessionHistory: preserveRestoredSessionHistory
        )
    }

    /// Either queues `request` behind a not-yet-available remote-workspace proxy
    /// endpoint or performs it immediately. While queued, the surface shows the
    /// display URL and a placeholder render intent without loading the web view.
    public func navigateWithoutInsecureHTTPPrompt(
        request: URLRequest,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool = false
    ) {
        guard let url = request.url else { return }
        host?.prepareWebViewDiscardStateForNavigation()
        if host?.usesRemoteWorkspaceProxy == true, host?.hasRemoteProxyEndpoint == false {
            pendingRemoteNavigation = PendingRemoteNavigation(
                request: request,
                recordTypedNavigation: recordTypedNavigation,
                preserveRestoredSessionHistory: preserveRestoredSessionHistory
            )
            host?.setCurrentDisplayURL(BrowserRemoteProxyURLRewriter.displayURL(for: url) ?? url)
            host?.setRenderIntent(forQueuedRemoteNavigationAttempting: url)
            return
        }
        host?.performNavigation(
            request: request,
            originalURL: url,
            recordTypedNavigation: recordTypedNavigation,
            preserveRestoredSessionHistory: preserveRestoredSessionHistory
        )
    }

    /// Replays the queued remote navigation once the proxy endpoint arrives, or
    /// directly once the pane turned local (a stranded queue pins the hidden pane
    /// as non-discardable forever).
    public func resumePendingRemoteNavigationIfNeeded() {
        guard host?.hasRemoteProxyEndpoint == true || host?.usesRemoteWorkspaceProxy == false,
              let navigation = pendingRemoteNavigation else {
            return
        }
        guard let originalURL = navigation.request.url else {
            pendingRemoteNavigation = nil
            host?.reevaluateHiddenWebViewDiscardScheduling(reason: "pending_remote_navigation_cleared")
            return
        }
        host?.performNavigation(
            request: navigation.request,
            originalURL: originalURL,
            recordTypedNavigation: navigation.recordTypedNavigation,
            preserveRestoredSessionHistory: navigation.preserveRestoredSessionHistory
        )
        pendingRemoteNavigation = nil
    }

    /// Navigates with smart URL/search detection: if `input` looks like a URL,
    /// navigates to it; otherwise performs a web search with the configured engine.
    public func navigateSmart(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = resolveNavigableURL(from: trimmed) {
            navigate(to: url, recordTypedNavigation: true)
            return
        }

        let searchConfiguration = BrowserSearchSettingsStore().currentConfiguration
        guard let searchURL = searchConfiguration.searchURL(query: trimmed) else { return }
        navigate(to: searchURL)
    }

    /// Resolves `input` to a navigable URL, or `nil` when it should be searched.
    public func resolveNavigableURL(from input: String) -> URL? {
        input.omnibarNavigableURL
    }
}
