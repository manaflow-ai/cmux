import Foundation
import Testing
@testable import CmuxNextBrowser

/// Back/forward entries saved before a relaunch (plans/cmux-next/browser.md,
/// "Session history across relaunch"): the model, and a Chromium tab
/// stepping through them without starting CEF.
@Suite struct RestoredHistoryTests {
    private static func entry(_ name: String, scrollY: Double? = nil) -> BrowserSavedEntry {
        BrowserSavedEntry(url: URL(string: "https://\(name).test/")!, title: name.uppercased(), scrollY: scrollY)
    }

    private static func page(_ name: String?) -> BrowserNavigationEntry {
        BrowserNavigationEntry(url: name.flatMap { URL(string: "https://\($0).test/") }, title: name?.uppercased())
    }

    private func makeTab(showing name: String) -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "t"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: false, canGoForward: false))
        tab.handle(.loadStart(browser: 1, url: "https://\(name).test/"))
        tab.handle(.loadEnd(browser: 1, httpStatus: 200))
        tab.handle(.loadingState(browser: 1, loading: false, canGoBack: false, canGoForward: false))
        return tab
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func steppingMovesTheShownEntryAcross() throws {
        var history = try #require(BrowserRestoredHistory(entries: ["a", "b", "c", "d"].map { Self.entry($0) }, current: 2))
        #expect(history.back == [Self.entry("a"), Self.entry("b")])
        #expect(history.forward == [Self.entry("d")])

        let shownC = Self.entry("c", scrollY: 80)
        #expect(history.goBack(2, from: shownC) == Self.entry("a"))
        #expect(history.back.isEmpty)
        #expect(history.forward == [Self.entry("b"), shownC, Self.entry("d")])
        #expect(history.goBack(from: Self.entry("a")) == nil)

        #expect(history.goForward(from: Self.entry("a")) == Self.entry("b"))
        #expect(history.back == [Self.entry("a")])
        #expect(history.forward == [shownC, Self.entry("d")])

        history.dropForward()
        #expect(history.forward.isEmpty && !history.isEmpty)
        #expect(BrowserRestoredHistory(entries: [Self.entry("a")], current: 0) == nil)
    }

    /// A step back into the saved entries replaces Chromium's first entry,
    /// so the saved forward entries list right after it.
    @Test func savedEntriesSitAroundChromiumsFirstEntry() throws {
        let history = try #require(BrowserRestoredHistory(entries: [Self.entry("x"), Self.entry("p"), Self.entry("y")], current: 1))
        let native = BrowserNavigationList(entries: [Self.page("p"), Self.page("q")], current: 0)
        let merged = history.merged(with: native, shown: Self.page("p"))
        #expect(merged.entries == ["x", "p", "y", "q"].map { Self.page($0) })
        #expect(merged.current == 1)

        let session = history.session(around: native, shown: Self.page("p"))
        #expect(session.entries.map { $0.url.host() } == ["x.test", "p.test", "y.test", "q.test"])
        #expect(session.current == 1)
    }

    @Test func aSavedSessionSkipsEntriesWithoutAURL() {
        let native = BrowserNavigationList(entries: [Self.page("p"), Self.page(nil), Self.page("q")], current: 2)
        let session = BrowserRestoredHistory.empty.session(around: native, shown: Self.page("q"))
        #expect(session.entries.map { $0.url.host() } == ["p.test", "q.test"])
        #expect(session.current == 1)
    }

    @Test func aRestoredTabOffersTheSavedEntriesAndStepsThroughThem() async {
        let tab = makeTab(showing: "b")
        #expect(!tab.state.canGoBack && !tab.state.canGoForward)
        tab.restoreSession([Self.entry("a"), Self.entry("b"), Self.entry("c")], current: 1)
        #expect(tab.state.canGoBack && tab.state.canGoForward)
        #expect(tab.navigationList()?.entries.map { $0.url?.host() } == ["a.test", "b.test", "c.test"])
        #expect(tab.navigationList()?.current == 1)

        tab.goBack()
        await Self.settle { tab.restored.history?.back.isEmpty == true && !tab.restored.isStepping }
        #expect(tab.state.url?.host() == "a.test")
        #expect(!tab.state.canGoBack && tab.state.canGoForward)
        #expect(tab.navigationList()?.entries.map { $0.url?.host() } == ["a.test", "b.test", "c.test"])
        #expect(tab.navigationList()?.current == 0)

        tab.goForward()
        await Self.settle { tab.restored.history?.back.count == 1 && !tab.restored.isStepping }
        #expect(tab.state.url?.host() == "b.test")
        #expect(tab.state.canGoBack && tab.state.canGoForward)
    }

    /// A new navigation of the user's drops the saved forward entries, as a
    /// browser does; the saved back entries stay behind Chromium's own.
    @Test func aNewNavigationDropsTheSavedForwardEntries() {
        let tab = makeTab(showing: "b")
        tab.restoreSession([Self.entry("a"), Self.entry("b"), Self.entry("c")], current: 1)
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: false, canGoForward: false))
        tab.handle(.loadStart(browser: 1, url: "https://d.test/"))
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: true, canGoForward: false))
        tab.handle(.loadEnd(browser: 1, httpStatus: 200))
        tab.handle(.loadingState(browser: 1, loading: false, canGoBack: true, canGoForward: false))
        #expect(tab.restored.history?.forward.isEmpty == true)
        #expect(tab.restored.history?.back == [Self.entry("a")])
        #expect(tab.state.canGoBack && !tab.state.canGoForward)
    }

    @Test func theSavedSessionKeepsTheScrollPositionsItKnows() async throws {
        let tab = makeTab(showing: "b")
        tab.restoreSession([Self.entry("a", scrollY: 100), Self.entry("b", scrollY: 250), Self.entry("c")], current: 1)
        let session = try #require(await tab.savedSession(measuringScroll: false))
        #expect(session.entries.map(\.scrollY) == [100, 250, nil])
        #expect(session.current == 1)
    }

    /// The URL a replace loads reaches the page as one string literal.
    @Test func aJavaScriptStringLiteralKeepsTheURLWhole() throws {
        let text = #"https://a.test/?q="x"&r=\n')</script>"#
        let literal = CEFRestoredSession.javaScriptString(text)
        #expect(literal.hasPrefix("\"") && literal.hasSuffix("\""))
        let decoded = try JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
        #expect(decoded == [text])
    }
}
