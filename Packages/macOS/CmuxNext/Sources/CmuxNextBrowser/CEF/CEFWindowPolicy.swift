import Foundation

/// What the runtime does with a request.
nonisolated enum CEFWindowDecision: Equatable, Sendable {
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

nonisolated enum CEFWindowRefusal: Equatable, Sendable {
    /// The request's store has no Chromium window, and cmux cannot open a
    /// tab of it by itself: an off-the-record store (an incognito window's
    /// pages) must never spill into a normal tab.
    case noWindow
}

nonisolated enum CEFWindowPolicy {
    static func decide(_ request: CEFWindowRequest, candidates: [CEFWindowCandidate],
                       links: CEFLinkContext = CEFLinkContext()) -> CEFWindowDecision {
        if request.kind == .offTheRecord || request.disposition == .offTheRecord {
            return .openOffTheRecord(url: request.url)
        }
        let disposition: BrowserNewTabDisposition
        switch placement(for: request, links: links) {
        case .tab(let tab): disposition = tab
        case .opener: return .loadInSource(url: request.url)
        case .download: return .downloadInSource(url: request.url)
        case .chromium: disposition = .foregroundTab
        }
        let sameProfile = candidates.filter { $0.profilePath == request.profilePath }
        let chosen = sameProfile.first(where: \.holdsSource)
            ?? sameProfile.first(where: \.lastShown)
            ?? sameProfile.first(where: \.visible)
            ?? sameProfile.first
        guard let chosen else {
            guard request.persistentProfile else { return .refuse(.noWindow) }
            return .openInNewTab(url: request.url, disposition: disposition)
        }
        return .insert(anchor: chosen.anchor, disposition: disposition)
    }

    /// Popups (window features, popup windows) keep `.popup`, so a host that
    /// shows them in a small floating pane can. A page's link request (a
    /// tab, or a window with a source tab, such as Shift-click) goes
    /// through the link mapping (`CEFLinkClicks`); everything else (Chromium's
    /// own UI, `chrome.windows.create` from an extension background) is a
    /// selected tab. `.opener` and `.download` need the source tab.
    static func placement(for request: CEFWindowRequest, links: CEFLinkContext) -> CEFLinkPlacement {
        let placement: CEFLinkPlacement
        switch request.kind {
        case .popup: return .tab(.popup)
        case .offTheRecord: return .tab(.foregroundTab)
        case .window, .app:
            guard request.sourceBrowser != 0, request.disposition.isLinkClick else { return .tab(.foregroundTab) }
            placement = links.placement(for: request.disposition, source: request.sourceBrowser, userGesture: request.userGesture)
        case .tab:
            placement = links.placement(for: request.disposition, source: request.sourceBrowser, userGesture: request.userGesture)
        }
        if placement == .opener || placement == .download, request.sourceBrowser == 0 || request.url.isEmpty {
            return .tab(.foregroundTab)
        }
        return placement
    }
}
