@testable import CmuxNextBrowser
import Foundation
import Testing

/// Phase A of the suggestion pipeline (plans/cmux-next/omnibar-suggestions.md):
/// the history source feeds the quick index on the phase A actor, inline
/// autocomplete follows the design's rules, open tabs become Switch to Tab
/// rows, and stale generations never deliver.
@MainActor
@Suite struct OmniboxPipelineTests {
    private func engine(_ history: InMemoryBrowserHistory) -> OmniboxSuggestionEngine {
        let engine = OmniboxSuggestionEngine(history: history)
        engine.now = { OmniboxFixtures.now }
        return engine
    }

    private func visit(_ history: InMemoryBrowserHistory, _ url: String, _ title: String? = nil, times: Int = 1) {
        for _ in 0..<times { history.recordVisit(url: URL(string: url)!, title: title, at: OmniboxFixtures.now) }
    }

    private func rows(_ engine: OmniboxSuggestionEngine, _ text: String) async -> [BrowserSuggestion] {
        await engine.historySettled()
        return await engine.suggestions(for: text)
    }

    @Test func theHistorySourceFeedsTheIndexAndForgetsDeletedRows() async throws {
        let history = InMemoryBrowserHistory()
        visit(history, "https://github.com/manaflow-ai/cmux", "cmux", times: 2)
        let engine = engine(history)
        // A visit after the snapshot arrives as a change.
        visit(history, "https://gist.github.com/", "Gists", times: 2)
        let found = await rows(engine, "gi")
        #expect(found.first?.kind == .search)
        #expect(Set(found.filter { $0.kind == .history }.map(\.url.absoluteString))
            == ["https://github.com/manaflow-ai/cmux", "https://gist.github.com/"])
        // Shift-Delete goes to the source; the index drops the row on its echo.
        engine.deleteSuggestion(URL(string: "https://gist.github.com/")!)
        #expect(!history.entries.contains { $0.url.absoluteString == "https://gist.github.com/" })
        let after = await rows(engine, "gi")
        #expect(after.filter { $0.kind == .history }.map(\.url.absoluteString) == ["https://github.com/manaflow-ai/cmux"])
        let local = await engine.local.historyContains(URL(string: "https://gist.github.com/")!)
        #expect(!local)
    }

    @Test func inlineAutocompleteNeedsAHostPrefixAndATypedOrFrequentURL() async {
        let history = InMemoryBrowserHistory()
        let engine = engine(history)
        visit(history, "https://github.com/", "GitHub", times: 3)
        #expect(await rows(engine, "git").allSatisfy { !$0.inlineCompletable }, "3 visits, never typed")
        visit(history, "https://github.com/", "GitHub")
        let frequent = await rows(engine, "git")
        #expect(frequent.firstIndex { $0.inlineCompletable } == 1, "4 visits: the top row after what-you-typed")
        // Typed once is enough.
        engine.noteTyped(URL(string: "https://news.example.com/")!)
        visit(history, "https://news.example.com/", "Daily")
        #expect(history.entries.first { $0.url.host() == "news.example.com" }?.typedCount == 1)
        #expect(await rows(engine, "news.ex").firstIndex { $0.inlineCompletable } == 1)
        // A label inside the host or a title word is not the start of the URL.
        visit(history, "https://mail.google.com/", "Inbox", times: 9)
        #expect(await rows(engine, "goo").allSatisfy { !$0.inlineCompletable })
        #expect(await rows(engine, "inbox").allSatisfy { !$0.inlineCompletable })
        #expect(await rows(engine, "mail.g").firstIndex { $0.inlineCompletable } == 1)
        // The setting turns it off.
        engine.inlineAutocomplete = false
        #expect(await rows(engine, "git").allSatisfy { !$0.inlineCompletable })
    }

    @Test func onlyTheMarkedRowCompletesInline() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("git", settle: false)
        let generation = sim.queries.last?.generation ?? 0
        let primary = OmniboxPhaseA.primary(for: "git", resolver: sim.resolver)
        var github = BrowserSuggestion(kind: .history, title: "GitHub", detail: "github.com", url: URL(string: "https://github.com/")!, score: 900)
        github.inlineCompletable = false
        sim.send(.suggestions(generation: generation, rows: [primary, github].compactMap { $0 }))
        #expect(sim.state.edit.inlineCompletion.isEmpty)
        #expect(sim.field.text == "git")
        sim.type("h", settle: false)
        github.inlineCompletable = true
        sim.send(.suggestions(generation: sim.queries.last?.generation ?? 0, rows: [primary, github].compactMap { $0 }))
        #expect(sim.field.text == "github.com")
        // A remote search row never completes, whatever its flag.
        var remote = BrowserSuggestion(kind: .search, title: "github copilot", detail: "", url: URL(string: "https://www.google.com/search?q=github+copilot")!, score: 999)
        remote.inlineCompletable = true
        #expect(OmnibarRules.inlineCompletion(for: remote, typed: "github") == nil)
    }

    @Test func inlineNeverFollowsADeleteOrAMovedCaret() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("git")
        #expect(sim.field.text == "github.com")
        sim.backspace()
        sim.answer()
        #expect(sim.field.text == "git", "no completion right after a delete")
        let moved = OmnibarSim()
        moved.focus()
        moved.type("gi", settle: false)
        moved.moveSelection(to: NSRange(location: 1, length: 0))
        moved.answer()
        #expect(moved.field.text == "gi", "no completion while the caret is not at the end")
    }

    @Test func openTabsAreSwitchToTabRowsAndEnterRevealsThem() async throws {
        let history = InMemoryBrowserHistory()
        let engine = engine(history)
        engine.openTabs = {
            [OmniboxTabRow(key: "tab-a", url: URL(string: "https://docs.swift.org/guide")!, title: "Swift Guide"),
             OmniboxTabRow(key: "tab-self", url: URL(string: "https://docs.swift.org/self")!, title: "Swift Self")]
        }
        let gate = OmniboxGenerationGate()
        gate.begin(1)
        var delivered: [BrowserSuggestion] = []
        for await delivery in engine.deliveries(for: OmniboxRequest(text: "swift", generation: 1, gate: gate, tabKey: "tab-self")) {
            if case .local(let rows) = delivery { delivered = rows }
        }
        let tab = try #require(delivered.first { $0.kind == .switchToTab })
        #expect(tab.tabKey == "tab-a" && tab.detail == Strings.switchToTab && !tab.inlineCompletable)
        #expect(!delivered.contains { $0.tabKey == "tab-self" })

        let sim = OmnibarSim()
        sim.focus()
        sim.type("swift", settle: false)
        sim.send(.suggestions(generation: sim.queries.last?.generation ?? 0, rows: delivered))
        let index = try #require(sim.state.popup.rows.firstIndex { $0.kind == .switchToTab })
        for _ in 0..<index { sim.key(.down) }
        sim.key(.enter(.currentTab))
        #expect(sim.ended == [.switchToTab(key: "tab-a")])
        #expect(sim.state.phase == .idle)
        // Shift-Enter loads the tab's page here instead.
        let here = OmnibarSim()
        here.focus()
        here.type("swift", settle: false)
        here.send(.suggestions(generation: here.queries.last?.generation ?? 0, rows: delivered))
        for _ in 0..<index { here.key(.down) }
        here.key(.enter(.newWindow))
        #expect(here.ended == [.commit(tab.url)])
    }

    @Test func enterOnTypedTextMarksTheVisitTyped() {
        let sim = OmnibarSim()
        sim.focus()
        sim.type("example.org")
        sim.key(.enter(.currentTab))
        guard case .commit(let url)? = sim.ended.first else {
            Issue.record("Enter did not commit: \(sim.ended)")
            return
        }
        #expect(url.host() == "example.org")
        #expect(sim.effects.contains(.typedNavigation(url)))
        let search = OmnibarSim()
        search.focus()
        search.type("hello world")
        search.key(.enter(.currentTab))
        #expect(!search.effects.contains { if case .typedNavigation = $0 { true } else { false } })
    }

    @Test func aStaleGenerationNeverDelivers() async {
        let history = InMemoryBrowserHistory()
        visit(history, "https://github.com/", "GitHub", times: 5)
        let engine = engine(history)
        await engine.historySettled()
        let gate = OmniboxGenerationGate()
        gate.begin(2)
        let stale = await engine.local.run(OmniboxLocalQuery(generation: 1, gate: gate, text: "git", resolver: OmniboxResolver()))
        #expect(stale == nil)
        let current = await engine.local.run(OmniboxLocalQuery(generation: 2, gate: gate, text: "git", resolver: OmniboxResolver()))
        #expect(current?.contains { $0.kind == .history } == true)
        // A stream whose generation was superseded ends without rows.
        var deliveries = 0
        for await _ in engine.deliveries(for: OmniboxRequest(text: "git", generation: 1, gate: gate)) { deliveries += 1 }
        #expect(deliveries == 0)
    }

    @Test func longInputGetsOnlyWhatYouTyped() async {
        let history = InMemoryBrowserHistory()
        visit(history, "https://github.com/", "GitHub", times: 5)
        let engine = engine(history)
        let long = "git " + String(repeating: "x", count: OmniboxText.maxInputLength)
        let found = await rows(engine, long)
        #expect(found.count == 1 && found.first?.kind == .search)
    }

    @Test func bookmarksCountAsTypedAndAPageShowsOnce() async {
        let history = InMemoryBrowserHistory()
        let engine = engine(history)
        engine.setBookmarks([OmniboxFixtures.row("https://kagi.com/", "Kagi", visits: 1, daysAgo: 200)])
        let found = await rows(engine, "kag")
        #expect(found.map(\.kind) == [.search, .bookmark])
        #expect(found.last?.inlineCompletable == true)
        visit(history, "https://kagi.com/", "Kagi", times: 30)
        let both = await rows(engine, "kag")
        #expect(both.filter { $0.url.host() == "kagi.com" }.count == 1)
    }
}
