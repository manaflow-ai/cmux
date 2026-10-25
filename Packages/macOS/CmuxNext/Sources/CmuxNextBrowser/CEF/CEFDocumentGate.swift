import Foundation

/// Which document a Chromium document bridge (`CEFMediaBridge`, `CEFVerificationBridge`) last
/// served, so it sends its DevTools calls once per document phase.
///
/// The bridges observe the whole tab state, which changes at every `pushState` and
/// `replaceState` (the address). Keyed on the address, each such change while a page was finished
/// cost the bridge its binding add and ready call again: 3 DevTools calls on the main thread per
/// address change. The key is the document instead: the navigation id at its commit
/// (`CEFTab.committedDocument`), with the phase. A same-document navigation commits nothing, so
/// it costs no call.
nonisolated struct CEFDocumentGate: Sendable {
    private var served: (document: BrowserNavigationID?, finished: Bool)?

    /// True once for each document at `.committed` and once at `.finished`; false for every other
    /// phase and for a repeat (the address moving within the document).
    /// - Parameter document: The navigation id the tab's current document committed with; nil
    ///   before the bridge saw a commit (a browser attached to a loaded page).
    mutating func admits(document: BrowserNavigationID?, phase: BrowserLoadPhase) -> Bool {
        let finished: Bool
        switch phase {
        case .committed: finished = false
        case .finished: finished = true
        default: return false
        }
        if let served, served.document == document, served.finished == finished { return false }
        served = (document, finished)
        return true
    }
}
