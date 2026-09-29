public import Foundation

/// A navigation attempt. Engines assign one per started navigation so that
/// late callbacks for a superseded navigation are ignored.
public nonisolated struct BrowserNavigationID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "nav#\(rawValue)" }
}

/// A load failure reported by an engine.
public nonisolated struct BrowserLoadError: Error, Hashable, Sendable {
    public var domain: String
    public var code: Int
    public var message: String
    public var failingURL: URL?

    public init(domain: String, code: Int, message: String, failingURL: URL? = nil) {
        self.domain = domain
        self.code = code
        self.message = message
        self.failingURL = failingURL
    }

    public init(_ error: any Error) {
        let ns = error as NSError
        self.init(
            domain: ns.domain,
            code: ns.code,
            message: ns.localizedDescription,
            failingURL: ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        )
    }

    /// True for failures that are not user-visible errors: a cancelled load
    /// (Stop, or a new navigation replacing this one) or WebKit's
    /// "frame load interrupted" when a response becomes a download.
    public var isBenignInterruption: Bool {
        (domain == NSURLErrorDomain && code == NSURLErrorCancelled)
            || (domain == "WebKitErrorDomain" && code == 102)
    }
}

/// Where the current page load is.
public nonisolated enum BrowserLoadPhase: Hashable, Sendable {
    /// Nothing loaded yet.
    case idle
    /// A navigation started; the old page is still on screen.
    case provisional
    /// The new document replaced the old one and is still loading.
    case committed
    /// The last navigation finished or was stopped after it committed.
    case finished
    /// The last navigation failed.
    case failed(BrowserLoadError)
}

/// Transport security of the committed page, as shown by the address bar.
public nonisolated enum BrowserSecurityState: Hashable, Sendable {
    case none
    case secure
    case insecure
    case local
}

/// Everything the chrome needs to render a tab. One value type shared by all
/// engines; engines produce it through `BrowserTabStateMachine`.
public nonisolated struct BrowserTabState: Hashable, Sendable {
    public var url: URL?
    public var title: String?
    public var faviconURL: URL?
    public var phase: BrowserLoadPhase
    /// Load progress in `0...1`. Meaningful only while `isLoading`.
    public var progress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// Page zoom factor, 1.0 = 100 %.
    public var zoom: Double
    /// True while page content is "fullscreen" inside the pane.
    public var isContentFullscreen: Bool
    public var security: BrowserSecurityState
    /// The navigation whose callbacks are currently accepted.
    public var activeNavigation: BrowserNavigationID?

    public init(
        url: URL? = nil,
        title: String? = nil,
        faviconURL: URL? = nil,
        phase: BrowserLoadPhase = .idle,
        progress: Double = 0,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        zoom: Double = 1,
        isContentFullscreen: Bool = false,
        security: BrowserSecurityState = .none,
        activeNavigation: BrowserNavigationID? = nil
    ) {
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.phase = phase
        self.progress = progress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.zoom = zoom
        self.isContentFullscreen = isContentFullscreen
        self.security = security
        self.activeNavigation = activeNavigation
    }

    public var isLoading: Bool {
        switch phase {
        case .provisional, .committed: true
        case .idle, .finished, .failed: false
        }
    }

    public var loadError: BrowserLoadError? {
        if case .failed(let error) = phase { return error }
        return nil
    }
}
