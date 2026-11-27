public import Foundation

/// Opens the tab for a window a page opens from a driven tab.
///
/// A popup of a tab a session created becomes that session's tab, under its
/// domain policy's content rules and its page clipboard guard, which go on
/// the tab when it is handed to the sessions. So such a tab is created with
/// no URL (it loads nothing), handed over, and only then loads its URL:
/// none of its requests (the document, its subresources, its frames)
/// precedes the rules, and no script of it runs without the guard. Other
/// popups (a user's tab's, or one only told to a session) open with their
/// URL, as before.
@MainActor
public struct BrowserReplPopupOpening<Tab> {
    private let create: (URL?) -> Tab?
    private let handOver: (Tab) -> Void
    private let load: (Tab, URL) -> Void

    /// - Parameters:
    ///   - create: Creates the tab, loading the URL when one is given.
    ///   - handOver: Attaches the sessions and puts the creating session's
    ///     rules and guard on the tab.
    ///   - load: Starts the tab's load of a URL.
    public init(create: @escaping (URL?) -> Tab?, handOver: @escaping (Tab) -> Void, load: @escaping (Tab, URL) -> Void) {
        self.create = create
        self.handOver = handOver
        self.load = load
    }

    /// Opens `url` in a new tab and hands it over; with `handOverFirst`
    /// the tab loads only after the hand-over.
    public func open(_ url: URL, handOverFirst: Bool) -> Tab? {
        guard handOverFirst else {
            guard let tab = create(url) else { return nil }
            handOver(tab)
            return tab
        }
        guard let tab = create(nil) else { return nil }
        handOver(tab)
        load(tab, url)
        return tab
    }
}
