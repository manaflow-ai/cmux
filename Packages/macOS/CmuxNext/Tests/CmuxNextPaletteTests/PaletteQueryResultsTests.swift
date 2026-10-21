import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A page that finds its own rows for the query (`PalettePageSpec.queryResults`, Search All
/// Windows) searches as you type: every edit asks it again, its rows show in its order with the
/// typed words highlighted, and an older query's answer never replaces a newer one's.
@MainActor
@Suite(.paletteRanker)
struct PaletteQueryResultsTests {
    private static func row(_ id: String, _ title: String) -> PaletteItem {
        PaletteItem(id: id, title: title, primary: PaletteCommand(id: "show", title: "Show", symbol: "return", effect: .perform {}))
    }

    private static func palette() -> PaletteController {
        _ = NSApplication.shared
        return PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
    }

    @Test func typedQueriesAreAnsweredByThePageInItsOrder() async {
        let palette = Self.palette()
        defer { palette.hide() }
        final class Asked { var queries: [String] = [] }
        let asked = Asked()
        palette.model.reset(to: PalettePageSpec(id: "live", title: "Live", placeholder: "", providers: [], queryResults: { query in
            asked.queries.append(query)
            return query.isEmpty ? [] : [Self.row("b", "zeta build failed"), Self.row("a", "Build ok")]
        }, filtersByQuery: false))
        await palette.model.settle()
        #expect(palette.model.rows.isEmpty)
        palette.model.send(.setQuery("build"))
        await palette.model.settle()
        #expect(asked.queries == ["", "build"])
        // The page's order, not the ranker's: "Build ok" would rank first as a prefix match.
        #expect(palette.model.rows.map(\.item.id) == ["b", "a"])
        #expect(palette.model.rows.first?.highlights == Array(5..<10))
        #expect(palette.model.rows.last?.highlights == Array(0..<5))
    }

    @Test func anOlderQueryNeverReplacesTheNewerOnesRows() async {
        let palette = Self.palette()
        defer { palette.hide() }
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (done, finish) = AsyncStream<Void>.makeStream()
        palette.model.reset(to: PalettePageSpec(id: "live", title: "Live", placeholder: "", providers: [], queryResults: { query in
            if query == "slow" {
                for await _ in gate { break }
                finish.yield()
                return [Self.row("old", "slow answer")]
            }
            return query.isEmpty ? [] : [Self.row("new", "\(query) answer")]
        }, filtersByQuery: false))
        await palette.model.settle()
        palette.model.send(.setQuery("slow"))
        palette.model.send(.setQuery("slower"))
        await palette.model.settle()
        #expect(palette.model.rows.map(\.item.id) == ["new"])
        open.yield()
        for await _ in done { break }
        await palette.model.settle()
        #expect(palette.model.rows.map(\.item.id) == ["new"])
    }
}
