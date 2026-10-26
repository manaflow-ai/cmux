#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

/// Where a page shows: the tab and pane whose view holds it (the oracle's `webviews` facet, p15-oracle-215).
public struct OraclePagePlace: Sendable, Hashable {
    public let tab: String
    public let pane: String

    public init(tab: String, pane: String) {
        self.tab = tab
        self.pane = pane
    }
}

/// The page host's half of the oracle's `webviews` facet (p15-oracle-215): which pages a person can reach, each
/// one's answer to `cmux.page.oracle.state`, and the change signal a `debug.oracle.wait_for` on the facet hears.
extension WebUIHost {
    /// Signals ``oracleChanges`` when `page` posts ``PageRouter/oracleStateChangedOp`` or its document starts or
    /// finishes loading. The host hooks each page it opens, and ``oracleStates(of:within:clock:)`` each page it asks,
    /// so a page made outside the host (a pooled Settings page) is hooked too. Hooking twice is one hook.
    public func observeOracleState(of page: PageWebView) {
        let feed = oracleChanges
        page.router.oracleStateChanged = { feed.signal() }
    }

    /// The pages a person can reach, in `pages` order, each with the place whose view holds it (found through its
    /// superviews; nil for a page in no tab, such as the Settings window). A page in no tab and no window, or inside
    /// `spare` (the New Tab spare), is left out. Pure over the views and the map.
    public static func oracleReachable<Page: NSView>(_ pages: [Page], places: [ObjectIdentifier: OraclePagePlace],
                                                     spare: NSView?) -> [(page: Page, place: OraclePagePlace?)] {
        pages.compactMap { page -> (page: Page, place: OraclePagePlace?)? in
            var holder: NSView? = page
            while let view = holder, places[ObjectIdentifier(view)] == nil { holder = view.superview }
            let place = holder.flatMap { places[ObjectIdentifier($0)] }
            let inSpare = spare.map { page.isDescendant(of: $0) } ?? false
            guard place != nil || page.window != nil, !inSpare else { return nil }
            return (page, place)
        }
    }

    /// Every page's answer, asked together on the main actor (each router lives there), so N slow pages cost one
    /// deadline, not N. Each asked page is hooked to ``oracleChanges``.
    public func oracleStates(of pages: [PageWebView], within deadline: Duration, clock: any Clock<Duration>)
        async -> [ObjectIdentifier: Result<PageWebView.OracleStateAnswer?, PageError>] {
        for page in pages { observeOracleState(of: page) }
        return await WebUIHost.oracleAnswers(pages, within: deadline, clock: clock)
    }

    /// The task group of ``oracleStates(of:within:clock:)``. A static function, as in the App before the move: the
    /// same group inside the instance method is a pattern Swift 6.2's region-based isolation checker refuses.
    private static func oracleAnswers(_ pages: [PageWebView], within deadline: Duration, clock: any Clock<Duration>)
        async -> [ObjectIdentifier: Result<PageWebView.OracleStateAnswer?, PageError>] {
        await withTaskGroup(of: (ObjectIdentifier, Result<PageWebView.OracleStateAnswer?, PageError>).self) { group in
            for page in pages {
                let id = ObjectIdentifier(page)
                group.addTask { @MainActor in
                    let answer: Result<PageWebView.OracleStateAnswer?, PageError>
                    do throws(PageError) {
                        answer = .success(try await page.oracleState(within: deadline, clock: clock))
                    } catch {
                        answer = .failure(error)
                    }
                    return (id, answer)
                }
            }
            var answers: [ObjectIdentifier: Result<PageWebView.OracleStateAnswer?, PageError>] = [:]
            for await (id, answer) in group { answers[id] = answer }
            return answers
        }
    }
}
#endif
