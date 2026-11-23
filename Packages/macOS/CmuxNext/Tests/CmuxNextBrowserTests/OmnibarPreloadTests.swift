import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Omnibox preloading (Chrome's `ChromeOmniboxClient::OnTextChanged` and
/// `AutocompleteActionPredictor::OnOmniboxOpenedUrl`): while the user edits,
/// the tab gets the typed text and the matches, the one Enter loads first;
/// when the edit ends, it learns the opened URL before Enter's load starts,
/// so the load can activate the tab's prerender of it.
@MainActor @Suite(.serialized, .closesItsWindows)
struct OmnibarPreloadTests {
    private final class Recorder: BrowserOmniboxPreloading {
        var log: [String] = []
        func omniboxPreload(text: String, matches: [OmniboxPreloadMatch]) -> OmniboxPreloadAction {
            log.append("preload \(text) " + matches.map { "\($0.kind.rawValue):\($0.url.absoluteString)" }.joined(separator: " "))
            return .prerender
        }

        func omniboxPreloadEnded(opened: URL?, learn: Bool) {
            log.append("ended \(opened?.absoluteString ?? "nil") learn \(learn)")
        }
    }

    private func row(_ kind: BrowserSuggestion.Kind, _ url: String) throws -> BrowserSuggestion {
        BrowserSuggestion(kind: kind, title: url, detail: url, url: try #require(URL(string: url)), score: 0)
    }

    private func editing(_ text: String, rows: [BrowserSuggestion]) -> OmnibarState {
        var state = OmnibarState()
        state.phase = .editing
        state.edit = .init(userText: text, selection: NSRange(location: text.utf16.count, length: 0))
        state.popup.rows = rows
        state.popup.selected = 0
        return state
    }

    /// Every tab of this Mac has the guard `exceptCloudDesktop` (RemoteLocalhostStorePlan), so a gate
    /// that wanted `.none` preloaded in no tab at all (bench `omnibar`, 0 of 16 prerendered).
    @Test func aTabOfThisMacPreloadsAnyPageButAnOpenDesktopOne() throws {
        let page = try #require(URL(string: "https://example.com/"))
        let desktop = try #require(URL(string: "https://m1.cloud-desktop.localhost/"))
        let local = try #require(URL(string: "http://localhost:3000/"))
        #expect(CEFTab.preloads(under: .none, opening: page))
        #expect(CEFTab.preloads(under: .exceptCloudDesktop, opening: page))
        #expect(CEFTab.preloads(under: .exceptCloudDesktop, opening: local))
        // An Open Desktop page reroutes to its machine's store: a prerender would reach this Mac's loopback.
        #expect(!CEFTab.preloads(under: .exceptCloudDesktop, opening: desktop))
        // A remote machine's stores: the guard must see every navigation.
        #expect(!CEFTab.preloads(under: .noLoopback, opening: page))
        #expect(!CEFTab.preloads(under: .loopbackOnly, opening: local))
    }

    @Test func theDefaultMatchGoesFirstAndRowsThatLoadNoPageAreLeftOut() throws {
        let rows = [try row(.navigate, "https://github.com/"),
                    try row(.search, "https://www.google.com/search?q=github"),
                    try row(.switchToTab, "https://github.com/manaflow-ai"),
                    try row(.history, "https://github.com/manaflow-ai/cmux"),
                    try row(.bookmark, "chrome://settings/"),
                    try row(.bookmark, "https://docs.github.com/")]
        var state = editing("gith", rows: rows)
        var request = try #require(OmnibarPreloadRequest.current(state))
        #expect(request.text == "gith")
        #expect(request.matches.map(\.kind) == [.urlWhatYouTyped, .searchSuggest, .historyURL, .bookmarkTitle])
        #expect(request.matches.first?.url.absoluteString == "https://github.com/")
        // An arrowed row is what Enter loads: it goes first.
        state.popup.selected = 3
        request = try #require(OmnibarPreloadRequest.current(state))
        #expect(request.matches.first == OmniboxPreloadMatch(url: try #require(URL(string: "https://github.com/manaflow-ai/cmux")), kind: .historyURL))
        #expect(request.matches.count == 4)
        // Enter on a Switch to Tab row loads nothing here: nothing preloads.
        state.popup.selected = 2
        #expect(OmnibarPreloadRequest.current(state) == nil)
    }

    @Test func nothingPreloadsForStaleRowsAKeywordSessionOrIMEText() throws {
        let rows = [try row(.navigate, "https://example.com/")]
        var state = editing("exa", rows: rows)
        #expect(OmnibarPreloadRequest.current(state) != nil)
        state.popup.stale = true
        #expect(OmnibarPreloadRequest.current(state) == nil, "rows for older text are not what Enter loads")
        state = editing("exa", rows: rows)
        state.edit.marked = NSRange(location: 0, length: 3)
        #expect(OmnibarPreloadRequest.current(state) == nil)
        state = editing("exa", rows: rows)
        state.keyword = OmnibarKeyword(extensionID: "ext", keyword: "k", name: "K")
        #expect(OmnibarPreloadRequest.current(state) == nil)
        state = editing("exa", rows: rows)
        state.phase = .focused
        #expect(OmnibarPreloadRequest.current(state) == nil, "an untouched URL is no edit")
    }

    @Test func theEndLearnsOnlyFromAnOpenPopupAndNeverFromPasteAndGo() throws {
        let url = try #require(URL(string: "https://example.com/"))
        let enter = OmnibarInput.key(.enter(.currentTab))
        let ending = OmnibarPreloadRequest.ending([.cancelQuery, .ended(.commit(url))], input: enter, popupWasOpen: true)
        #expect(ending?.opened == url)
        #expect(ending?.learn == true)
        #expect(OmnibarPreloadRequest.ending([.ended(.commit(url))], input: enter, popupWasOpen: false)?.learn == false)
        #expect(OmnibarPreloadRequest.ending([.ended(.commit(url))], input: .pasteAndGo("example.com"), popupWasOpen: true)?.learn == false)
        #expect(OmnibarPreloadRequest.ending([.ended(.open(url, .newBackgroundTab))], input: enter, popupWasOpen: true)?.learn == true)
        // Escape is Chrome's OnRevert: every match counts as missed.
        let cancel = OmnibarPreloadRequest.ending([.ended(.cancel)], input: .key(.escape), popupWasOpen: false)
        #expect(cancel?.opened == nil)
        #expect(cancel?.learn == true)
        #expect(OmnibarPreloadRequest.ending([.ended(.blur)], input: .focusLost, popupWasOpen: true)?.learn == false)
        #expect(OmnibarPreloadRequest.ending([.cancelQuery], input: enter, popupWasOpen: true) == nil)
    }

    /// Through the controller: one request per changed text or rows, then the end, which reaches the tab
    /// before the commit loads the page (Enter's load then activates the prerender).
    @Test func theControllerFeedsTheTabAndEndsBeforeTheCommitLoads() throws {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        bar.frame = NSRect(x: 10, y: 20, width: 600, height: 34)
        window.contentView!.addSubview(bar)
        bar.update(url: URL(string: "https://example.com/a"), security: .secure)
        let recorder = Recorder()
        bar.controller.setPreloader(recorder)
        bar.onEvent = { event in
            if case .didEndEditing(.commit(let url)) = event { recorder.log.append("load \(url.absoluteString)") }
        }
        let controller = bar.controller
        controller.send(.focusGained(.keyboard))
        controller.send(.dropped("github.com"))
        #expect(recorder.log.isEmpty, "no rows yet")
        let rows = [try row(.navigate, "https://github.com/"), try row(.history, "https://github.com/manaflow-ai/cmux")]
        controller.send(.suggestions(generation: controller.state.generation, rows: rows))
        controller.send(.suggestions(generation: controller.state.generation, rows: rows))
        #expect(recorder.log == ["preload github.com 0:https://github.com/ 1:https://github.com/manaflow-ai/cmux"],
                "the same text and rows are sent once")
        controller.send(.key(.enter(.currentTab)))
        #expect(recorder.log.dropFirst() == ["ended https://github.com/ learn true", "load https://github.com/"])
    }

    /// Escape that reverts typed text has no end effect; it is still Chrome's OnRevert: every match missed.
    @Test func escapeThatRevertsTypedTextCountsTheMatchesAsMissed() throws {
        let bar = AddressBarView()
        let recorder = Recorder()
        bar.update(url: URL(string: "https://example.com/a"), security: .secure)
        bar.controller.setPreloader(recorder)
        bar.controller.send(.focusGained(.keyboard))
        bar.controller.send(.dropped("swift.org"))
        bar.controller.send(.suggestions(generation: bar.controller.state.generation, rows: [try row(.navigate, "https://swift.org/")]))
        bar.controller.send(.key(.escape))
        if bar.controller.state.phase == .editing { bar.controller.send(.key(.escape)) }
        #expect(recorder.log.count == 2)
        #expect(recorder.log.last == "ended nil learn true")
        #expect(bar.controller.lastPreload == nil)
    }

    @Test func aTabThatLosesTheOmnibarMidEditForgetsTheEdit() throws {
        let bar = AddressBarView()
        let first = Recorder(), second = Recorder()
        bar.controller.setPreloader(first)
        bar.controller.send(.focusGained(.keyboard))
        bar.controller.send(.dropped("swift.org"))
        bar.controller.send(.suggestions(generation: bar.controller.state.generation, rows: [try row(.navigate, "https://swift.org/")]))
        bar.controller.setPreloader(second)
        #expect(first.log.last == "ended nil learn false")
        #expect(second.log.isEmpty)
    }
}
