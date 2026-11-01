public import Foundation

/// A navigation the page asked for, outside its own origin (react-pages.md 1, engine neutral).
public nonisolated struct PageNavigation: Sendable, Equatable {
    public let url: URL
    /// The user clicked a link (not a redirect, a script or a form the page sent by itself).
    public let userClicked: Bool
    /// The navigation is in the page's main frame (not in a frame inside it).
    public let mainFrame: Bool
    /// The target frame's current document before this navigation (blank on its first load).
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
    /// (``PageDescriptor/isEntryDocument(_:)``). The artifact endpoint is a one-shot direct child
    /// of the agent page; its opaque document and a passive srcdoc cannot navigate elsewhere.
    /// `hook` decides every other navigation; without a hook, only a link the user clicked in the
    /// main frame opens outside, and everything else (an automatic redirect, a frame) is cancelled.
    public static func policy(for url: URL?, page: PageDescriptor, userClicked: Bool, mainFrame: Bool,
                              targetFrameURL: URL? = nil, sourceFrameURL: URL? = nil,
                              hook: ((PageNavigation) -> Policy)?) -> Policy {
        guard let url else { return .cancel }
        // A passive srcdoc frame's initial document is browser-created and has no scheme-handler
        // request. Permit only that initial about:srcdoc load from the direct agent document. A
        // later request from a srcdoc source is handled by the restricted-context check below.
        let initialSrcdoc = url.absoluteString == "about:srcdoc" && !mainFrame &&
            page.id.lowercased() == PageArtifactFrame.pageID &&
            PageArtifactFrame.isAgentPageURL(sourceFrameURL) &&
            (targetFrameURL == nil || targetFrameURL?.absoluteString == "about:blank" ||
             targetFrameURL?.absoluteString == "about:srcdoc")
        if initialSrcdoc { return .allow }
        if page.id.lowercased() == PageArtifactFrame.pageID,
           sourceFrameURL?.absoluteString == "about:srcdoc" {
            return .cancel
        }
        // A page's own passive frames (``PageDescriptor/passiveFrames``): the page's document may
        // set a frame's srcdoc; a srcdoc document can neither navigate nor be navigated elsewhere.
        if page.passiveFrames, !mainFrame {
            let srcdoc = url.absoluteString == "about:srcdoc"
            if sourceFrameURL?.absoluteString == "about:srcdoc" { return .cancel }
            if targetFrameURL?.absoluteString == "about:srcdoc", !srcdoc { return .cancel }
            if srcdoc { return page.owns(sourceFrameURL) ? .allow : .cancel }
        }
        if PageArtifactFrame.contextRestricted(frame: targetFrameURL, parent: sourceFrameURL) ||
            PageArtifactFrame.navigationRefused(mainFrame: mainFrame, frame: targetFrameURL,
                                                parent: sourceFrameURL, target: url) {
            return .cancel
        }
        if page.owns(url) { return !mainFrame || page.isEntryDocument(url) ? .allow : .cancel }
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
    /// The agent chat's Chromium spike (the `agent.chromium` Debug toggle): lifts
    /// ``PageWebKitReason/agentChat``, so the agent page follows ``PageEnginePolicy`` as any other
    /// page does. Off by default.
    public var chromiumAgentChat: Bool
    /// A first click in a window that is not key reaches the page even when its descriptor does
    /// not opt in (``PageDescriptor/acceptsFirstMouse``): a page in the window's chrome, such as
    /// the sidebar's Updated card, while a Chromium page's own window holds the key. Off by default.
    public var acceptsFirstMouse: Bool

    public init(fullFrameRate: Bool = false, requiresWebKit: PageWebKitReason? = nil, chromiumAgentChat: Bool = false,
                acceptsFirstMouse: Bool = false) {
        self.fullFrameRate = fullFrameRate
        self.requiresWebKit = requiresWebKit
        self.chromiumAgentChat = chromiumAgentChat
        self.acceptsFirstMouse = acceptsFirstMouse
    }

    public static let standard = PageEngineOptions()

    /// WebKit's feature that renders a page at the display-rate divisor nearest 60 fps.
    public static let near60FPSFeature = "PreferPageRenderingUpdatesNear60FPSEnabled"  // WebKitRenderRate.near60FPSFeature
}
