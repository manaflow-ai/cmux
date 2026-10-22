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
        // The slow answer ignores cancellation, so only the palette's own check can drop it.
        final class Gate { var resume: CheckedContinuation<Void, Never>?; var answered = false }
        let gate = Gate()
        palette.model.reset(to: PalettePageSpec(id: "live", title: "Live", placeholder: "", providers: [], queryResults: { query in
            if query == "slow" {
                await withCheckedContinuation { gate.resume = $0 }
                gate.answered = true
                return [Self.row("old", "slow answer")]
            }
            return query.isEmpty ? [] : [Self.row("new", "\(query) answer")]
        }, filtersByQuery: false))
        await palette.model.settle()
        palette.model.send(.setQuery("slow"))
        await Task.yield()
        palette.model.send(.setQuery("slower"))
        await palette.model.settle()
        #expect(palette.model.rows.map(\.item.id) == ["new"])
        while gate.resume == nil { await Task.yield() }
        gate.resume?.resume()
        while !gate.answered { await Task.yield() }
        await Task.yield()
        await palette.model.settle()
        #expect(palette.model.rows.map(\.item.id) == ["new"])
    }
}
