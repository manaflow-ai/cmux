import Foundation

/// What the runtime does with a request.
nonisolated enum CEFWindowDecision: Equatable, Sendable {
    /// Chromium adds the tab to the window of `anchor`; the runtime adopts
    /// it as a cmux tab when it arrives there.
    case insert(anchor: Int32, disposition: BrowserNewTabDisposition)
    /// No Chromium window of that profile exists: Chromium opens nothing
    /// and cmux opens `url` in a new tab of its own.
    case openInNewTab(url: String, disposition: BrowserNewTabDisposition)
    case openOffTheRecord(url: String)
    /// Chromium opens nothing, and cmux tells the user why.
    case refuse(CEFWindowRefusal)
}

nonisolated enum CEFWindowRefusal: Equatable, Sendable {
    /// Incognito: cmux has no Chromium incognito window, and a normal tab
    /// would store the history and cookies the user wanted to keep out.
    case offTheRecord
    case noWindow
}

nonisolated enum CEFWindowPolicy {
    static func decide(_ request: CEFWindowRequest, candidates: [CEFWindowCandidate]) -> CEFWindowDecision {
        if request.kind == .offTheRecord || request.disposition == .offTheRecord {
            return .refuse(.offTheRecord)
        }
        let disposition = tabDisposition(for: request)
        let sameProfile = candidates.filter { $0.profilePath == request.profilePath }
        let chosen = sameProfile.first(where: \.holdsSource)
            ?? sameProfile.first(where: \.lastShown)
            ?? sameProfile.first(where: \.visible)
            ?? sameProfile.first
        guard let chosen else {
            return .openInNewTab(url: request.url, disposition: disposition)
        }
        return .insert(anchor: chosen.anchor, disposition: disposition)
    }

    /// Popups (window features, popup windows) keep `.popup`, so a host that
    /// shows them in a small floating pane can; everything else is a tab
    /// that is selected unless Chromium asked for a background tab.
    static func tabDisposition(for request: CEFWindowRequest) -> BrowserNewTabDisposition {
        switch request.kind {
        case .popup: return .popup
        case .window, .app, .offTheRecord: return .foregroundTab
        case .tab: return request.disposition.tabDisposition ?? .foregroundTab
        }
    }
}
