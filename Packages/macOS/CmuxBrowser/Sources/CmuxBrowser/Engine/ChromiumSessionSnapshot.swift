public import Foundation

/// Observable page and lifecycle metadata for one Chromium session.
public struct ChromiumSessionSnapshot: Equatable, Sendable {
    /// Current child-process and CDP lifecycle state.
    public let state: ChromiumSessionState
    /// Last main-frame URL reported by Chromium.
    public let currentURL: URL?
    /// Last document title reported by Chromium.
    public let title: String?
    /// Loopback endpoint surfaced only when external debugging is enabled.
    public let externallyVisibleEndpoint: BrowserCDPEndpoint?
    /// Whether Chromium can traverse to an older navigation entry.
    public let canGoBack: Bool
    /// Whether Chromium can traverse to a newer navigation entry.
    public let canGoForward: Bool
    /// Back-history URLs ordered oldest-first.
    public let backHistoryURLs: [URL]?
    /// Forward-history URLs ordered nearest-first.
    public let forwardHistoryURLs: [URL]?
    /// Whether the active main frame is still loading.
    public let isLoading: Bool
    /// Monotonically increasing main-frame navigation revision.
    public let navigationRevision: UInt64

    /// Creates an immutable session snapshot.
    ///
    /// - Parameters:
    ///   - state: Current process and connection lifecycle.
    ///   - currentURL: Last main-frame URL, when known.
    ///   - title: Last document title, when known.
    ///   - externallyVisibleEndpoint: Advertised loopback CDP endpoint, when enabled.
    ///   - canGoBack: Whether an older history entry exists.
    ///   - canGoForward: Whether a newer history entry exists.
    ///   - backHistoryURLs: Back entries ordered oldest-first.
    ///   - forwardHistoryURLs: Forward entries ordered nearest-first.
    ///   - isLoading: Whether the main frame is loading.
    ///   - navigationRevision: Monotonic main-frame navigation revision.
    public init(
        state: ChromiumSessionState,
        currentURL: URL? = nil,
        title: String? = nil,
        externallyVisibleEndpoint: BrowserCDPEndpoint? = nil,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        backHistoryURLs: [URL]? = nil,
        forwardHistoryURLs: [URL]? = nil,
        isLoading: Bool = false,
        navigationRevision: UInt64 = 0
    ) {
        self.state = state
        self.currentURL = currentURL
        self.title = title
        self.externallyVisibleEndpoint = externallyVisibleEndpoint
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.backHistoryURLs = backHistoryURLs
        self.forwardHistoryURLs = forwardHistoryURLs
        self.isLoading = isLoading
        self.navigationRevision = navigationRevision
    }
}
