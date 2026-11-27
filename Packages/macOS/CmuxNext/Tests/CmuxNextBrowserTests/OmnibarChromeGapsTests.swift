import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// The Chrome omnibox gaps left after the first parity pass (u2573,
/// PARITY.md): tab to search, Opt-Cmd-F search, Always Show Full URLs,
/// Manage Search Engines, site icons in rows, and the typed-address http
/// fallback.
@MainActor
@Suite(.closesItsWindows)
struct OmnibarChromeGapsTests {
    // MARK: Fixtures

    private var resolver: OmniboxResolver {
        var resolver = OmniboxResolver()
        resolver.keywords = OmnibarKeyword.searchEngines(default: resolver.searchEngine)
        return resolver
    }

    private func reduce(_ inputs: [OmnibarInput]) -> (OmnibarState, [OmnibarEffect]) {
        reduce(OmnibarState(), inputs)
    }

    private func reduce(_ state: OmnibarState, _ inputs: [OmnibarInput]) -> (OmnibarState, [OmnibarEffect]) {
        var state = state
        var effects: [OmnibarEffect] = []
        let resolver = self.resolver
        for input in inputs {
            let step = OmnibarReducer.reduce(state, input, resolver: resolver)
            state = step.state
            effects += step.effects
        }
        return (state, effects)
    }

    /// Keys typed one by one after `start` (focus unless given).
    private func typed(_ text: String, from start: String = "", focus: Bool = true) -> [OmnibarInput] {
        var inputs: [OmnibarInput] = focus ? [.focusGained(.keyboard)] : []
        var current = start
        for character in text {
            current.append(character)
            inputs.append(.fieldChanged(.init(text: current, selection: NSRange(location: current.utf16.count, length: 0)), .insert))
        }
        return inputs
    }

    private func commits(_ effects: [OmnibarEffect]) -> [URL] {
        effects.compactMap { effect -> URL? in
            if case .ended(.commit(let url)) = effect { return url }
            return nil
        }
    }

    // MARK: Tab to search

    /// Chrome: `youtube.com` then Tab searches YouTube; the chip says
    /// "Search YouTube" and Enter loads YouTube's results, no extension.
    @Test func tabAfterAnEngineSiteSearchesThatEngine() throws {
        let (session, started) = reduce(typed("youtube.com") + [.key(.tab)])
        #expect(session.keyword?.searchEngine?.id == "youtube")
        #expect(session.edit.userText.isEmpty)
        #expect(!started.contains { if case .keywordStarted = $0 { true } else { false } }, "no extension takes part")
        #expect(OmnibarPresentation(session).chip == .engineKeyword(label: "Search YouTube"))
        let (_, effects) = reduce(session, typed("lofi beats", focus: false) + [.key(.enter(.currentTab))])
        #expect(commits(effects) == [URL(string: "https://www.youtube.com/results?search_query=lofi%20beats")!])
    }

    /// The keyword and a space start the session as Tab does.
    @Test func anEngineKeywordAndASpaceStartTheSearch() {
        // After the space the field holds only the text after the keyword.
        let (session, _) = reduce(typed("github.com "))
        #expect(session.keyword?.searchEngine?.id == "github")
        let (state, effects) = reduce(session, typed("swift testing", focus: false) + [.key(.enter(.currentTab))])
        #expect(state.keyword == nil)
        #expect(commits(effects) == [URL(string: "https://github.com/search?q=swift%20testing")!])
    }

    /// Enter with nothing typed in a session opens the engine's site.
    @Test func enterWithNoTextOpensTheEngineSite() {
        let (_, effects) = reduce(typed("wikipedia.org") + [.key(.tab), .key(.enter(.currentTab))])
        #expect(commits(effects) == [URL(string: "https://en.wikipedia.org/")!])
    }

    /// Backspace at the start leaves the session with the keyword back.
    @Test func backspaceLeavesTheEngineSearch() {
        let (state, _) = reduce(typed("youtube.com") + [.key(.tab), .key(.backspaceAtStart)])
        #expect(state.keyword == nil)
        #expect(state.edit.userText == "youtube.com")
    }

    // MARK: Opt-Cmd-F

    /// Chrome's Search the Web: the focused bar searches with the default engine.
    @Test func searchTheWebSearchesWithTheDefaultEngine() throws {
        let (session, _) = reduce([.focusGained(.keyboard), .key(.searchWithDefaultEngine)])
        #expect(session.keyword?.searchEngine == .google)
        #expect(OmnibarPresentation(session).chip == .engineKeyword(label: "Search Google"))
        let (_, effects) = reduce(session, typed("example.com", focus: false) + [.key(.enter(.currentTab))])
        #expect(commits(effects) == [URL(string: "https://www.google.com/search?q=example.com")!], "an address searches too")
    }

    /// The address bar starts the search once focus lands (the focus
    /// coordinator focuses it first).
    @Test func beginSearchWaitsForTheFocus() {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        bar.frame = NSRect(x: 10, y: 20, width: 600, height: 34)
        window.contentView!.addSubview(bar)
        bar.beginSearch()
        #expect(bar.state.keyword == nil)
        bar.focus()
        #expect(bar.state.keyword?.searchEngine == .google)
    }

    // MARK: Always Show Full URLs

    /// The resting bar shows the whole address, host emphasized.
    @Test func showFullURLsKeepsSchemeAndWWW() throws {
        let page = try #require(URL(string: "https://www.example.com/a?b=1"))
        let (compact, _) = reduce(OmnibarState(pageURL: page), [])
        #expect(compact.fieldText == "example.com/a?b=1")
        let (full, _) = reduce(compact, [.showFullURLsChanged(true)])
        #expect(full.fieldText == "https://www.example.com/a?b=1")
        let host = try #require(BrowserURLDisplay.hostRange(in: full.fieldText, for: page))
        #expect((full.fieldText as NSString).substring(with: host) == "www.example.com")
        // A focusing click no longer elides: the full URL, all selected.
        let (focused, _) = reduce(full, [.focusGained(.mouse)])
        #expect(!focused.elided)
        #expect(focused.fieldText == "https://www.example.com/a?b=1")
    }

    /// The bar follows the engine's setting from the start.
    @Test func theBarFollowsTheSetting() {
        let engine = OmniboxSuggestionEngine()
        engine.apply(OmniboxConfiguration(showFullURLs: true))
        let bar = AddressBarView(suggestionEngine: engine)
        bar.update(url: URL(string: "https://example.com/"), security: .none)
        #expect(bar.state.fieldText == "https://example.com/")
    }

    /// The right-click menu has both items; the toggle asks the App to
    /// write the setting, the other opens search engine settings.
    @Test func theMenuTogglesFullURLsAndManagesEngines() throws {
        let bar = AddressBarView()
        var written: [Bool] = []
        var managed = 0
        bar.suggestionEngine.display.setShowsFullURLs = { written.append($0) }
        bar.suggestionEngine.display.manageSearchEngines = { managed += 1 }
        let items = bar.omnibarMenuItems()
        let toggle = try #require(items.first { $0.title == "Always Show Full URLs" })
        #expect(toggle.state == .off)
        let manage = try #require(items.first { $0.title == "Manage Search Engines…" })
        _ = (toggle.target as AnyObject?)?.perform(toggle.action, with: toggle)
        _ = (manage.target as AnyObject?)?.perform(manage.action, with: manage)
        #expect(written == [true])
        #expect(managed == 1)
    }

    // MARK: Site icons

    /// Page rows show the site's icon once it loads; searches keep their glyph.
    @Test func pageRowsShowTheSiteIcon() async {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        var asked: [URL] = []
        let source: (URL) async -> NSImage? = { url in
            asked.append(url)
            return image
        }
        let page = SuggestionRowView(suggestion: BrowserSuggestion(kind: .history, title: "Example", detail: "", url: URL(string: "https://example.com/a")!, score: 1),
                                     faviconSource: source)
        await page.faviconTask?.value
        #expect(page.showsFavicon)
        #expect(asked == [URL(string: "https://example.com/a")!])
        let search = SuggestionRowView(suggestion: BrowserSuggestion(kind: .search, title: "cats", detail: "", url: URL(string: "https://www.google.com/search?q=cats")!, score: 1),
                                       faviconSource: source)
        #expect(search.faviconTask == nil)
        #expect(!search.showsFavicon)
        let typed = SuggestionRowView(suggestion: BrowserSuggestion(kind: .navigate, title: "exam", detail: "", url: URL(string: "https://exam/")!, score: 1),
                                      faviconSource: source)
        #expect(typed.faviconTask == nil)
        #expect(asked == [URL(string: "https://example.com/a")!])
    }

    // MARK: http fallback

    /// Enter on a scheme-less address marks its https load as an upgrade;
    /// a typed `https://` is not one.
    @Test func typedAddressesAreMarkedAsUpgrades() {
        let (_, upgraded) = reduce(typed("example.com") + [.key(.enter(.currentTab))])
        #expect(upgraded.contains(.typedHTTPSUpgrade(URL(string: "https://example.com")!)))
        let (_, explicit) = reduce(typed("https://example.com") + [.key(.enter(.currentTab))])
        #expect(!explicit.contains { if case .typedHTTPSUpgrade = $0 { true } else { false } })
    }

    /// A refused https connection loads the address once over http; a host
    /// that does not resolve, or a page that connected, does not.
    @Test func aRefusedUpgradeFallsBackToHTTP() throws {
        let https = try #require(URL(string: "https://example.com"))
        func failing(_ code: Int) -> BrowserTabState {
            let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: nil))
            let id = tab.makeNavigationID()
            tab.simulate(.started(id, url: https))
            tab.simulate(.failed(id, BrowserLoadError(domain: NSURLErrorDomain, code: code, message: "", failingURL: https)))
            return tab.state
        }
        var fallback = HTTPSUpgradeFallback()
        fallback.expect(https)
        #expect(fallback.observe(failing(NSURLErrorCannotConnectToHost))?.absoluteString == "http://example.com")
        #expect(fallback.pending == nil, "once")

        fallback.expect(https)
        #expect(fallback.observe(failing(NSURLErrorCannotFindHost)) == nil)

        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: nil))
        fallback.expect(https)
        let id = tab.makeNavigationID()
        tab.simulate(.started(id, url: https))
        #expect(fallback.observe(tab.state) == nil)
        tab.simulate(.finished(id))
        #expect(fallback.observe(tab.state) == nil)
        #expect(fallback.pending == nil, "it connected")
    }

    /// Chromium's connection and certificate errors fall back; its name errors do not.
    @Test func chromiumErrorsThatFallBack() {
        func error(_ code: Int) -> BrowserLoadError { BrowserLoadError(domain: "net", code: code, message: "") }
        #expect(HTTPSUpgradeFallback.fallsBack(error(-102)), "refused")
        #expect(HTTPSUpgradeFallback.fallsBack(error(-107)), "TLS protocol")
        #expect(HTTPSUpgradeFallback.fallsBack(error(-202)), "certificate authority")
        #expect(!HTTPSUpgradeFallback.fallsBack(error(-105)), "name not resolved")
        #expect(!HTTPSUpgradeFallback.fallsBack(error(-106)), "offline")
    }
}
