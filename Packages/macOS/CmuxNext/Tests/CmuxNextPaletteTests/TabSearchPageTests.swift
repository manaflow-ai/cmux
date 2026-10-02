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
        model.reset(to: TabSearchPage.make(source: source, style: style, query: query, now: { fixed }))
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
        model.reset(to: TabSearchPage.make(source: source, style: .recent, now: { fixed }))
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
        model.reset(to: TabSearchPage.make(source: source, style: .recent, now: { fixed }))
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

    @Test func selectionAfterRemovingPrefersTheNextRow() {
        #expect(PaletteModel.selection(afterRemoving: "b", from: ["a", "b", "c"]) == "c")
        #expect(PaletteModel.selection(afterRemoving: "c", from: ["a", "b", "c"]) == "b")
        #expect(PaletteModel.selection(afterRemoving: "a", from: ["a"]) == nil)
        #expect(PaletteModel.selection(afterRemoving: "z", from: ["a"]) == nil)
    }

    @Test func cmdWIsTheCloseChord() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                 isARepeat: false, keyCode: 13))
        #expect(PaletteKeyMap.isCloseItem(event))
        let registry = ActionRegistry.standard()
        #expect(PaletteKeyMap.command(for: event, actionsMenuOpen: false, queryIsEmpty: true, registry: registry) == .closeItem)
        #expect(PaletteKeyMap.command(for: event, actionsMenuOpen: true, queryIsEmpty: true, registry: registry) == nil)
    }
}
