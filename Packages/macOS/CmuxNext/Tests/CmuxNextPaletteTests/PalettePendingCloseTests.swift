import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A close held while search runs must not migrate to a different query or page.
/// The main actor does not yield between the key and navigation, so these tests
/// exercise that ordering without timing, sleeps, or a window.
@MainActor
struct PalettePendingCloseTests {
    @MainActor private final class Source {
        var closed: [String] = []

        func page(_ id: String, query: String = "") -> PalettePageSpec {
            PalettePageSpec(id: id, title: id, placeholder: "", providers: [],
                            initialQuery: query, ownsCloseKey: true, queryResults: { [self] query in
                let rowID = "\(id):\(query)"
                return AsyncStream { continuation in
                    let item = PaletteItem(
                        id: rowID, title: rowID,
                        primary: PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {}),
                        closeCommand: PaletteCommand(id: "close", title: "Close", symbol: "xmark", effect: .performKeepingOpen {
                            self.closed.append(rowID)
                        })
                    )
                    continuation.yield(closed.contains(rowID) ? [] : [item])
                    continuation.finish()
                }
            }, filtersByQuery: false)
        }
    }

    @Test func queryEditCancelsHeldClose() async {
        let source = Source()
        let model = PaletteModel(persistence: nil)
        defer { model.send(.close) }
        model.reset(to: source.page("tabs", query: "old"))
        #expect(model.handle(.closeItem))
        #expect(model.pendingClose)
        model.query = "new"
        await model.settle()
        #expect(model.rows.map(\.id) == ["tabs:new"])
        #expect(source.closed.isEmpty)
        #expect(!model.pendingClose)
    }

    @Test func escapeClearingQueryCancelsHeldClose() async {
        let source = Source()
        let model = PaletteModel(persistence: nil)
        defer { model.send(.close) }
        model.reset(to: source.page("tabs", query: "old"))
        #expect(model.handle(.closeItem))
        model.handle(.escape)
        await model.settle()
        #expect(model.query.isEmpty)
        #expect(model.rows.map(\.id) == ["tabs:"])
        #expect(source.closed.isEmpty)
    }

    @Test func enteringAnotherPageCancelsHeldClose() async {
        let source = Source()
        let model = PaletteModel(persistence: nil)
        defer { model.send(.close) }
        model.reset(to: source.page("tabs"))
        #expect(model.handle(.closeItem))
        model.push(source.page("other-tabs"))
        await model.settle()
        #expect(model.currentPageID == "other-tabs")
        #expect(model.rows.map(\.id) == ["other-tabs:"])
        #expect(source.closed.isEmpty)
    }

    @Test func returningToParentPageCancelsHeldClose() async {
        let source = Source()
        let model = PaletteModel(persistence: nil)
        defer { model.send(.close) }
        model.reset(to: source.page("tabs"))
        await model.settle()
        model.push(source.page("other-tabs"))
        #expect(model.handle(.closeItem))
        model.handle(.escape)
        await model.settle()
        #expect(model.currentPageID == "tabs")
        #expect(model.rows.map(\.id) == ["tabs:"])
        #expect(source.closed.isEmpty)
    }

    @Test func replacingPageWithSameQueryCancelsHeldClose() async {
        let source = Source()
        let model = PaletteModel(persistence: nil)
        defer { model.send(.close) }
        model.reset(to: source.page("tabs"))
        #expect(model.handle(.closeItem))
        model.replaceCurrentPage(with: source.page("other-tabs"))
        await model.settle()
        #expect(model.currentPageID == "other-tabs")
        #expect(model.rows.map(\.id) == ["other-tabs:"])
        #expect(source.closed.isEmpty)
    }

    @Test func sameQueryRefreshStillClosesOnce() async {
        let source = Source()
        let model = PaletteModel(persistence: nil)
        defer { model.send(.close) }
        model.reset(to: source.page("tabs", query: "old"))
        #expect(model.handle(.closeItem))
        model.reload()
        await model.settle()
        #expect(source.closed == ["tabs:old"])
        #expect(model.rows.isEmpty)
        #expect(!model.pendingClose)
    }
}
