import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A page that finds its own rows for the query (`PalettePageSpec.queryResults`, Search All
/// Windows) searches as you type: every edit asks it again, its rows show in its order with the
/// typed words highlighted, each answer shows while the page reads on, and an older query's
/// answer never replaces a newer one's.
@MainActor
@Suite(.paletteRanker)
struct PaletteQueryResultsTests {
    /// Yields to the main actor until `done`, at most 10,000 times (false then, instead of hanging).
    private static func yield(until done: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if done() { return true }
            await Task.yield()
        }
        return done()
    }

    private static func row(_ id: String, _ title: String) -> PaletteItem {
        PaletteItem(id: id, title: title, primary: PaletteCommand(id: "show", title: "Show", symbol: "return", effect: .perform {}))
    }

    private static func answer(_ items: [PaletteItem]) -> AsyncStream<[PaletteItem]> {
        AsyncStream { continuation in
            continuation.yield(items)
            continuation.finish()
        }
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
            return Self.answer(query.isEmpty ? [] : [Self.row("b", "zeta build failed"), Self.row("a", "Build ok")])
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
            guard query == "slow" else { return Self.answer(query.isEmpty ? [] : [Self.row("new", "\(query) answer")]) }
            return AsyncStream { continuation in
                Task { @MainActor in
                    await withCheckedContinuation { gate.resume = $0 }
                    gate.answered = true
                    continuation.yield([Self.row("old", "slow answer")])
                    continuation.finish()
                }
            }
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

    /// https://github.com/manaflow-ai/cmux/issues/25640: Search All Windows read every terminal
    /// before it answered, so one slow or unreachable terminal kept the typed query on its
    /// prompt row. Each answer now shows as it comes, and the field's spinner runs until the
    /// last one.
    @Test func eachAnswerShowsBeforeThePageHasFinishedReading() async {
        let palette = Self.palette()
        defer { palette.hide() }
        final class Feed { var continuation: AsyncStream<[PaletteItem]>.Continuation? }
        let feed = Feed()
        palette.model.reset(to: PalettePageSpec(id: "live", title: "Live", placeholder: "", providers: [], queryResults: { query in
            guard !query.isEmpty else { return Self.answer([Self.row("prompt", "Type to search")]) }
            let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
            feed.continuation = continuation
            continuation.yield([Self.row("title", "zqx in a title")])
            return stream
        }, filtersByQuery: false))
        await palette.model.settle()
        #expect(palette.model.rows.map(\.item.id) == ["prompt"])
        palette.model.send(.setQuery("zqx"))
        #expect(await Self.yield(until: { palette.model.rows.map(\.item.id) == ["title"] }))
        // The first answer is on screen while the page still reads.
        #expect(palette.model.isLoading)
        feed.continuation?.yield([Self.row("title", "zqx in a title"), Self.row("terminal", "echo zqx")])
        #expect(await Self.yield(until: { palette.model.rows.count >= 2 }))
        #expect(palette.model.rows.map(\.item.id) == ["title", "terminal"])
        #expect(palette.model.isLoading)
        feed.continuation?.finish()
        await palette.model.settle()
        #expect(palette.model.rows.map(\.item.id) == ["title", "terminal"])
        #expect(!palette.model.isLoading)
    }
}
