public import Foundation

/// A navigation the page asked for, outside its own origin (react-pages.md 1, engine neutral).
public nonisolated struct PageNavigation: Sendable, Equatable {
    public let url: URL
    /// The user clicked a link (not a redirect, a script or a form the page sent by itself).
    public let userClicked: Bool
    /// The navigation is in the page's main frame (not in a frame inside it).
    public let mainFrame: Bool

    public init(url: URL, userClicked: Bool, mainFrame: Bool) {
        self.url = url
        self.userClicked = userClicked
        self.mainFrame = mainFrame
    }

    /// What the host does with a navigation.
    public enum Policy: Sendable, Equatable {
        /// Load it in the page (only a page's hook may allow another origin, for example a frame).
        case allow
        /// Cancel it and open the URL outside the page (``PageWebView/onOpenExternal``).
        case openExternal
        case cancel
    }

    /// The policy for `url`: the page's own origin never reaches `hook`; the main frame stays on
    /// the page's own document (``PageDescriptor/isEntryDocument(_:)``), and a frame inside it may
    /// load any document of the origin. `hook` decides every other navigation; without a hook, only
    /// a link the user clicked in the main frame opens outside, and everything else (an automatic
    /// redirect, a frame) is cancelled.
    public static func policy(for url: URL?, page: PageDescriptor, userClicked: Bool, mainFrame: Bool,
                              hook: ((PageNavigation) -> Policy)?) -> Policy {
        guard let url else { return .cancel }
        if page.owns(url) { return !mainFrame || page.isEntryDocument(url) ? .allow : .cancel }
        let navigation = PageNavigation(url: url, userClicked: userClicked, mainFrame: mainFrame)
        if let hook { return hook(navigation) }
        return userClicked && mainFrame && url.scheme?.lowercased() != "about" ? .openExternal : .cancel
    }
}

/// Engine options a page asks for. Each engine maps them (WebKit today, CEF later); an engine
/// without the option ignores it.
public nonisolated struct PageEngineOptions: Sendable, Equatable {
    /// How fast the page renders in WebKit (``PageRenderRate``). ``PageRenderRate/display`` by
    /// default: the display's full rate, near 60 fps in Low Power Mode, as browser tabs.
    public var renderRate: PageRenderRate
    /// Keeps this page on WebKit whatever `browser.defaultEngine` says, for this reason (the update
    /// island floats over the window: ``PageWebKitReason/transparentOverlay``). Nil lets
    /// ``PageEnginePolicy`` decide.
    public var requiresWebKit: PageWebKitReason?
    /// The agent chat's Chromium spike (the `agent.chromium` Debug toggle): lifts
    /// ``PageWebKitReason/agentChat``, so the agent page follows ``PageEnginePolicy`` as any other
    /// page does. Off by default.
    public var chromiumAgentChat: Bool

    public init(renderRate: PageRenderRate = .display, requiresWebKit: PageWebKitReason? = nil, chromiumAgentChat: Bool = false) {
        self.renderRate = renderRate
        self.requiresWebKit = requiresWebKit
        self.chromiumAgentChat = chromiumAgentChat
    }

    public static let standard = PageEngineOptions()
}
