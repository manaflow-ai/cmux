import AppKit
import CmuxNextActions
import CmuxNextPalette
import Foundation
import Testing

/// The Search Tabs page in the palette model: open tabs above recently
/// closed ones, Return focuses or reopens, Cmd-W closes the row and keeps
/// the palette open with the next row selected.
@Suite struct TabSearchPageTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func open(_ source: MockTabSearchSource, query: String = "", style: TabSearchStyle = .recent) -> PaletteModel {
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        let fixed = now
        model.reset(to: PalettePageSpec.tabSearch(source: source, style: style, query: query, now: { fixed }))
        return model
    }

    @Test func emptyQueryListsOpenThenClosedAndSelectsThePreviousTab() {
        let model = open(MockTabSearchSource(now: now))
        #expect(model.sections.map(\.section.id) == ["tabSearch.open", "tabSearch.closed"])
        #expect(model.rows.map(\.id) == ["tab:tab_1", "tab:tab_2", "tab:tab_3", "tab:tab_4", "tab:tab_5", "tab:tab_6",
                                         "closed:local/tab_7", "closed:local/tab_8"])
        #expect(model.selectedRowID == "tab:tab_2")
    }

    @Test func returnFocusesAnOpenTabAndReopensAClosedOne() {
        let source = MockTabSearchSource(now: now)
        let model = open(source)
        model.handle(.submit)
        #expect(source.focused == ["tab_2"])
        let again = open(source)
        again.handle(.moveToLast)
        again.handle(.submit)
        #expect(source.reopened == ["local/tab_8"])
    }

    @Test func cmdWClosesTheRowKeepsThePaletteOpenAndSelectsTheNextRow() {
        let source = MockTabSearchSource(now: now)
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        var dismissed = false
        model.onDismiss = { dismissed = true }
        let fixed = now
        model.reset(to: PalettePageSpec.tabSearch(source: source, style: .recent, now: { fixed }))
        #expect(model.handle(.closeItem))
        #expect(source.closed == ["tab_2"])
        #expect(!dismissed)
        #expect(!model.rows.contains { $0.id == "tab:tab_2" })
        #expect(model.selectedRowID == "tab:tab_3")
        // The last row: the one before it is selected.
        model.handle(.moveToLast)
        #expect(model.handle(.closeItem))
        #expect(source.forgotten == ["local/tab_8"])
        #expect(model.selectedRowID == "closed:local/tab_7")
    }

    @Test func cmdWOnARowWithoutACloseCommandFallsThrough() {
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        model.reset(to: PalettePageSpec(id: "root", title: "Commands", placeholder: "Search", providers: [
            StaticPaletteProvider(id: "static", items: [PaletteItem(id: "a", title: "Alpha", primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}))]),
        ]))
        #expect(!model.handle(.closeItem))
        #expect(model.rows.count == 1)
    }

    @Test func aRefusedCloseKeepsTheRowAndShowsWhy() {
        let source = MockTabSearchSource(now: now)
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        model.performer = { handler in
            handler()
            return "Pinned tabs need confirmation"
        }
        let fixed = now
        model.reset(to: PalettePageSpec.tabSearch(source: source, style: .recent, now: { fixed }))
        #expect(model.handle(.closeItem))
        #expect(model.rows.contains { $0.id == "tab:tab_2" })
        #expect(model.selectedItem?.subtitle == "Pinned tabs need confirmation")
    }

    @Test func typedQueriesKeepClosedTabsBelowOpenTabs() async {
        let model = open(MockTabSearchSource(now: now), query: "api")
        await model.settle()
        #expect(model.query == "api")
        let sections = model.sections.map(\.section.id)
        #expect(sections.first == "tabSearch.open")
        #expect(sections.last == "tabSearch.closed")
        #expect(model.selectedRowID?.hasPrefix("tab:") == true)
    }

    @Test func groupedStyleShowsAWorkspaceSectionPerGroup() {
        let model = open(MockTabSearchSource(now: now), style: .grouped)
        #expect(model.sections.map(\.section.title).prefix(2) == ["api", "web"])
        #expect(model.sections.last?.section.id == "tabSearch.closed")
    }

    /// The owner's change event re-reads the shown page at once: the tab
    /// leaves Open Tabs and appears under Recently Closed with no other
    /// trigger (no wait for the next layout change).
    @Test func aChangeEventUpdatesTheShownPageAtOnce() async {
        let source = MockTabSearchSource(now: now)
        let model = open(source)
        let live = TabSearchLiveUpdates()
        live.follow(source, in: model)
        source.entries.removeAll { $0.id == "tab_3" }
        source.entries.append(TabSearchEntry(id: "local/tab_3", kind: .terminal, title: "bun dev", order: 9,
                                             state: .closed(closedAt: now)))
        source.emitChange()
        for _ in 0..<1_000 where !model.rows.contains(where: { $0.id == "closed:local/tab_3" }) { await Task.yield() }
        #expect(model.rows.contains { $0.id == "closed:local/tab_3" })
        #expect(!model.rows.contains { $0.id == "tab:tab_3" })
        live.stop()
    }

    @Test func liveUpdatesStopOnceThePageIsGone() async {
        let source = MockTabSearchSource(now: now)
        let model = open(source)
        let live = TabSearchLiveUpdates()
        live.follow(source, in: model)
        model.reset(to: PalettePageSpec(id: "root", title: "Commands", placeholder: "Search", providers: []))
        source.emitChange()
        for _ in 0..<50 { await Task.yield() }
        #expect(model.currentPageID == "root")
        #expect(model.rows.isEmpty)
    }

    @Test func selectionAfterRemovingStaysInTheSection() {
        let rows = [(id: "a", section: "open"), (id: "b", section: "open"), (id: "c", section: "closed"), (id: "d", section: "closed")]
        #expect(PaletteModel.selection(afterRemoving: "a", from: rows) == "b")
        // The last open row: the previous open row, never a closed one.
        #expect(PaletteModel.selection(afterRemoving: "b", from: rows) == "a")
        #expect(PaletteModel.selection(afterRemoving: "d", from: rows) == "c")
        #expect(PaletteModel.selection(afterRemoving: "a", from: [(id: "a", section: "open")]) == nil)
        #expect(PaletteModel.selection(afterRemoving: "z", from: rows) == nil)
    }

    @Test func thePageOwnsCmdWEvenWithoutARow() {
        let model = open(MockTabSearchSource(entries: [], now: now))
        #expect(model.rows.isEmpty)
        #expect(model.currentPageOwnsCloseKey)
        // Consumed: it must never reach the main menu's Close Tab.
        #expect(model.handle(.closeItem))
    }

    @Test func cmdWWithTheActionsMenuOpenClosesTheMenuAndTheRow() {
        let source = MockTabSearchSource(now: now)
        let model = open(source)
        model.handle(.toggleActions)
        #expect(model.actionsMenu != nil)
        #expect(model.handle(.closeItem))
        #expect(model.actionsMenu == nil)
        #expect(source.closed == ["tab_2"])
    }

    @Test func cmdWDuringASearchWaitsForItsResults() async {
        let source = MockTabSearchSource(now: now)
        let model = open(source)
        model.query = "localhost"
        #expect(model.handle(.closeItem))
        await model.settle()
        // Ran on the query's top match, not on the row selected before.
        #expect(source.closed == ["tab_4"])
    }

    @Test func cmdWIsTheCloseChord() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                 isARepeat: false, keyCode: 13))
        #expect(PaletteKeyMap.isCloseItem(event))
        let registry = ActionRegistry.standard()
        #expect(PaletteKeyMap.command(for: event, actionsMenuOpen: false, queryIsEmpty: true, registry: registry) == .closeItem)
        #expect(PaletteKeyMap.command(for: event, actionsMenuOpen: true, queryIsEmpty: true, registry: registry) == .closeItem)
    }
}
