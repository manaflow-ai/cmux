public import Foundation

/// The observable state of a page.
///
/// Engines report a new value through ``BrowserPageEvent/stateChanged(_:)``
/// whenever any field changes.
public struct BrowserPageState: Equatable, Hashable, Sendable {
    /// The committed (or provisional, while loading) page URL.
    public var url: URL?
    /// The document title.
    public var title: String?
    /// `true` while a main-frame navigation is in progress.
    public var isLoading: Bool
    /// Load progress in `0...1`; meaningful while ``isLoading``.
    public var estimatedProgress: Double
    /// `true` when the back list is not empty.
    public var canGoBack: Bool
    /// `true` when the forward list is not empty.
    public var canGoForward: Bool
    /// Back list URLs, oldest first.
    public var backURLs: [URL]
    /// Forward list URLs, nearest first.
    public var forwardURLs: [URL]
    /// Page zoom, `1` is 100%.
    public var pageZoom: Double
    /// `true` when every resource of the page loaded over a secure connection.
    public var hasOnlySecureContent: Bool
    /// `true` while page content is fullscreen.
    public var isContentFullscreen: Bool
    /// Set when the content process ended; cleared when a navigation starts.
    public var processExit: BrowserPageProcessExit?
    /// `true` while the page stopped handling input.
    public var isUnresponsive: Bool

    /// Creates a page state; every field defaults to an idle blank page.
    /// - Parameters:
    ///   - url: The page URL.
    ///   - title: The document title.
    ///   - isLoading: Whether a navigation is in progress.
    ///   - estimatedProgress: Load progress in `0...1`.
    ///   - canGoBack: Whether the back list is not empty.
    ///   - canGoForward: Whether the forward list is not empty.
    ///   - backURLs: Back list URLs, oldest first.
    ///   - forwardURLs: Forward list URLs, nearest first.
    ///   - pageZoom: Page zoom.
    ///   - hasOnlySecureContent: Whether every resource loaded securely.
    ///   - isContentFullscreen: Whether page content is fullscreen.
    ///   - processExit: How the content process ended, if it did.
    ///   - isUnresponsive: Whether the page stopped handling input.
    public init(
        url: URL? = nil,
        title: String? = nil,
        isLoading: Bool = false,
        estimatedProgress: Double = 0,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        backURLs: [URL] = [],
        forwardURLs: [URL] = [],
        pageZoom: Double = 1,
        hasOnlySecureContent: Bool = false,
        isContentFullscreen: Bool = false,
        processExit: BrowserPageProcessExit? = nil,
        isUnresponsive: Bool = false
    ) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.estimatedProgress = estimatedProgress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.backURLs = backURLs
        self.forwardURLs = forwardURLs
        self.pageZoom = pageZoom
        self.hasOnlySecureContent = hasOnlySecureContent
        self.isContentFullscreen = isContentFullscreen
        self.processExit = processExit
        self.isUnresponsive = isUnresponsive
    }
}
