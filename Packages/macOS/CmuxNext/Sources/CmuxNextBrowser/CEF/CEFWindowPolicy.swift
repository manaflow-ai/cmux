import Foundation

/// What the runtime does with a request.
nonisolated enum CEFWindowDecision: Equatable, Sendable, Decodable {
    /// Chromium adds the tab to the window of `anchor`; the runtime adopts
    /// it as a cmux tab when it arrives there.
    case insert(anchor: Int32, disposition: BrowserNewTabDisposition)
    /// No Chromium window of that profile exists: Chromium opens nothing
    /// and cmux opens `url` in a new tab of its own.
    case openInNewTab(url: String, disposition: BrowserNewTabDisposition)
    /// A modified click mapped to the current tab: Chromium opens nothing
    /// and the requesting tab loads `url`.
    case loadInSource(url: String)
    /// A modified click mapped to a download: Chromium opens nothing and
    /// the requesting tab downloads `url` (`CEFDownloads`).
    case downloadInSource(url: String)
    /// An incognito request ("Open Link in Incognito Window", New
    /// Incognito Window): Chromium opens nothing, and cmux opens `url` (or
    /// nothing, when empty) in a cmux incognito window, or in the source
    /// tab's incognito window when the source is incognito.
    case openOffTheRecord(url: String)
    /// Chromium opens nothing, and cmux tells the user why.
    case refuse(CEFWindowRefusal)
}

nonisolated enum CEFWindowRefusal: String, Equatable, Sendable, Decodable {
    /// The request's store has no Chromium window, and cmux cannot open a
    /// tab of it by itself: an off-the-record store (an incognito window's
    /// pages) must never spill into a normal tab.
    case noWindow
}

/// The one decision for every window Chromium wants to open, asked of cmux-browser-rules
/// (`decide_window`, `window_placement`, with their tests). Incognito requests go off the record. A
/// popup keeps `.popup`; a page's link request follows the link mapping (`CEFLinkClicks`);
/// everything else is a selected tab. The tab goes to the same store's window that holds the
/// source, else the one shown last, else a visible one, else the first; with none, a persistent
/// store opens a cmux tab and an off-the-record one is refused.
nonisolated enum CEFWindowPolicy {
    private struct Request: Encodable {
        let request: CEFWindowRequest
        let candidates: [CEFWindowCandidate]
        let links: CEFLinkContext.Facts
    }

    static func decide(_ request: CEFWindowRequest, candidates: [CEFWindowCandidate],
                       links: CEFLinkContext = CEFLinkContext()) -> CEFWindowDecision {
        let facts = Request(request: request, candidates: candidates, links: links.facts(source: request.sourceBrowser))
        return BrowserRules.call("browser_rules_window_decide", facts, as: CEFWindowDecision.self) ?? .refuse(.noWindow)
    }

    static func placement(for request: CEFWindowRequest, links: CEFLinkContext) -> CEFLinkPlacement {
        let facts = Request(request: request, candidates: [], links: links.facts(source: request.sourceBrowser))
        return BrowserRules.call("browser_rules_window_placement", facts, as: CEFLinkPlacement.self) ?? .tab(.foregroundTab)
    }
}
