public import Foundation

/// A navigation the page asked for, outside its own origin (react-pages.md 1, engine neutral).
public nonisolated struct PageNavigation: Sendable, Equatable {
    public let url: URL
    /// The user clicked a link (not a redirect, a script or a form the page sent by itself).
    public let userClicked: Bool
    /// The navigation is in the page's main frame (not in a frame inside it).
    public let mainFrame: Bool
    /// The target frame's current document, before this navigation (blank on its first load).
    public let targetFrameURL: URL?
    /// The document that requested the navigation, which may differ from the target frame.
    public let sourceFrameURL: URL?

    public init(url: URL, userClicked: Bool, mainFrame: Bool,
                targetFrameURL: URL? = nil, sourceFrameURL: URL? = nil) {
        self.url = url
        self.userClicked = userClicked
        self.mainFrame = mainFrame
        self.targetFrameURL = targetFrameURL
        self.sourceFrameURL = sourceFrameURL
    }

    /// What the host does with a navigation.
    public enum Policy: Sendable, Equatable {
        /// Load it in the page (only a page's hook may allow another origin, for example a frame).
        case allow
        /// Cancel it and open the URL outside the page (``PageWebView/onOpenExternal``).
        case openExternal
        case cancel
    }

    /// The policy for `url`: the main frame stays on the page's own document
    /// (``PageDescriptor/isEntryDocument(_:)``). `hook` decides subframe navigations, including
    /// the page's own origin, so a host can confine an untrusted frame after its first load. It
    /// also decides main-frame navigations outside the page's origin. Without a hook, subframes
    /// may load only the page's origin, and only a link the user clicked in the main frame opens
    /// outside; everything else is cancelled.
    public static func policy(for url: URL?, page: PageDescriptor, userClicked: Bool, mainFrame: Bool,
                              targetFrameURL: URL? = nil, sourceFrameURL: URL? = nil,
                              hook: ((PageNavigation) -> Policy)?) -> Policy {
        guard let url else { return .cancel }
        if page.owns(url), mainFrame || hook == nil { return !mainFrame || page.isEntryDocument(url) ? .allow : .cancel }
        let navigation = PageNavigation(url: url, userClicked: userClicked, mainFrame: mainFrame,
                                        targetFrameURL: targetFrameURL, sourceFrameURL: sourceFrameURL)
        if let hook { return hook(navigation) }
        return userClicked && mainFrame && url.scheme?.lowercased() != "about" ? .openExternal : .cancel
    }
}

/// Engine options a page asks for. Each engine maps them (WebKit today, CEF later); an engine
/// without the option ignores it.
public nonisolated struct PageEngineOptions: Sendable, Equatable {
    /// Render at the display's full rate instead of the rate nearest 60 fps (the agent pane's
    /// render rate). Off by default.
    public var fullFrameRate: Bool
    /// Keeps this page on WebKit whatever `browser.defaultEngine` says, for this reason (the update
    /// island floats over the window: ``PageWebKitReason/transparentOverlay``). Nil lets
    /// ``PageEnginePolicy`` decide.
    public var requiresWebKit: PageWebKitReason?

    public init(fullFrameRate: Bool = false, requiresWebKit: PageWebKitReason? = nil) {
        self.fullFrameRate = fullFrameRate
        self.requiresWebKit = requiresWebKit
    }

    public static let standard = PageEngineOptions()

    /// WebKit's feature that renders a page at the display-rate divisor nearest 60 fps.
    public static let near60FPSFeature = "PreferPageRenderingUpdatesNear60FPSEnabled"  // WebKitRenderRate.near60FPSFeature
}
