import AppKit
@testable import CmuxNextPalette
import Testing

/// Full-model coverage for Search Tabs' section-boundary close contract. The
/// provider is intentionally mutable so each test exercises reload and row
/// rebuilding, rather than only the reducer in isolation.
@MainActor
@Suite(.paletteRanker)
struct SearchTabsSectionBoundaryTests {
    final class Fixture {
        var items: [PaletteItem] = []
        var forgets = 0
        var closes = 0
    }

    private func item(_ id: String, title: String, section: PaletteSection, fixture: Fixture, forgets: Bool = false) -> PaletteItem {
        let primary = PaletteCommand(id: "open", title: "Open", effect: .performKeepingOpen {})
        let close = PaletteCommand(id: "close", title: "Close", effect: .performKeepingOpen {
            if forgets { fixture.forgets += 1 } else { fixture.closes += 1 }
            fixture.items.removeAll { $0.id == id }
        })
        return PaletteItem(id: id, title: title, section: section, primary: primary, closeCommand: close)
    }

    private func page(_ fixture: Fixture) -> PalettePageSpec {
        PalettePageSpec(id: "tab-search", title: "Search Tabs", placeholder: "Search", providers: [
            AsyncPaletteProvider(id: "tabs", immediateItems: fixture.items) {
                fixture.items
            }
        ], ownsCloseKey: true, keepsSectionOrder: true)
    }

    @Test func repeatedCloseAfterRefreshDoesNotForgetHistory() async {
        let fixture = Fixture()
        let open = PaletteSection(id: "open", title: "Open", order: 0)
        let closed = PaletteSection(id: "closed", title: "Recently Closed", order: 1)
        let tab = item("tab:A", title: "A", section: open, fixture: fixture)
        let history = item("closed:H", title: "H", section: closed, fixture: fixture, forgets: true)
        fixture.items = [tab, history]
        let model = PaletteModel(persistence: nil)
        model.reset(to: page(fixture))
        await model.settle()
        model.select(rowID: tab.id)
        model.handle(.closeItem)
        await model.settle()
        #expect(model.selectedRowID == nil)
        #expect(fixture.forgets == 0)
        model.handle(.closeItem)
        await model.settle()
        #expect(fixture.forgets == 0)
    }

    @Test func queuedSecondCloseWhileRefreshIsInFlightCannotForgetHistory() async {
        let fixture = Fixture()
        let open = PaletteSection(id: "open", title: "Open", order: 0)
        let closed = PaletteSection(id: "closed", title: "Recently Closed", order: 1)
        let tab = item("tab:A", title: "A", section: open, fixture: fixture)
        let history = item("closed:H", title: "H", section: closed, fixture: fixture, forgets: true)
        fixture.items = [tab, history]
        let model = PaletteModel(persistence: nil)
        model.reset(to: page(fixture))
        await model.settle()
        model.select(rowID: tab.id)
        model.handle(.closeItem)
        // Cmd-W is consumed while the close-triggered provider refresh runs.
        model.handle(.closeItem)
        await model.settle()
        #expect(fixture.forgets == 0)
        #expect(model.selectedRowID == nil)
    }

    @Test func delayedClosedEntryDoesNotBecomeImplicitSelection() async {
        let fixture = Fixture()
        let open = PaletteSection(id: "open", title: "Open", order: 0)
        let closed = PaletteSection(id: "closed", title: "Recently Closed", order: 1)
        let tab = item("tab:A", title: "A", section: open, fixture: fixture)
        fixture.items = [tab]
        let model = PaletteModel(persistence: nil)
        model.reset(to: page(fixture))
        await model.settle()
        model.select(rowID: tab.id)
        model.handle(.closeItem)
        fixture.items = [item("closed:A", title: "A", section: closed, fixture: fixture, forgets: true)]
        model.reload()
        await model.settle()
        #expect(model.selectedRowID == nil)
        model.handle(.closeItem)
        await model.settle()
        #expect(fixture.forgets == 0)
    }

    @Test func explicitlySelectedHistoryStillRunsForget() async {
        let fixture = Fixture()
        let closed = PaletteSection(id: "closed", title: "Recently Closed", order: 1)
        let history = item("closed:H", title: "H", section: closed, fixture: fixture, forgets: true)
        fixture.items = [history]
        let model = PaletteModel(persistence: nil)
        model.reset(to: page(fixture))
        await model.settle()
        model.select(rowID: history.id)
        model.handle(.closeItem)
        await model.settle()
        #expect(fixture.forgets == 1)
    }
}
