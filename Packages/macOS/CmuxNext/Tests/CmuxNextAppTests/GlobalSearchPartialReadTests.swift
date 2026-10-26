import CmuxNextPalette
import Testing
@testable import CmuxNextApp

/// https://github.com/manaflow-ai/cmux/issues/25640: Search All Windows waited for every
/// terminal and transcript before it answered a query. One terminal whose daemon did not answer
/// (another machine, a daemon handing off) kept the typed query on "Type to search every
/// terminal, agent session and tab" for as long as that read took. A query is now answered from
/// the titles at once and again as each read lands; "No matches" waits for the last read.
@MainActor
struct GlobalSearchPartialReadTests {
    private static func source(_ id: String, _ title: String) -> GlobalSearchCorpus.Source {
        GlobalSearchCorpus.Source(tabID: id, title: title, terminal: nil, agent: nil)
    }

    private static func ids(_ items: [PaletteItem]) -> [String] { items.map(\.id) }

    /// The answers for `query` until one satisfies `done`.
    private static func answer(_ query: String, _ reader: GlobalSearchReader, until done: ([PaletteItem]) -> Bool) async -> [PaletteItem] {
        for await items in GlobalSearchPage.answers(query, corpus: reader, byTab: [:], reveal: { _, _ in }) where done(items) {
            return items
        }
        return []
    }

    @Test func aQueryIsAnsweredWhileATerminalIsStillBeingRead() async {
        let sources = [Self.source("fast", "build"), Self.source("hung", "deploy")]
        let (reads, feed) = AsyncStream.makeStream(of: GlobalSearchCorpus.Read.self, bufferingPolicy: .bufferingOldest(2))
        let reader = GlobalSearchReader(sources, reads: reads)
        defer { reader.release() }

        // Titles are searchable before any read lands.
        #expect(await reader.state.value.hits(["deploy"]).hits.map(\.tabID) == ["hung"])

        // The first terminal's text lands; the second never answers.
        feed.yield(GlobalSearchCorpus.Read(
            index: 0, texts: [GlobalSearchCorpus.Content(origin: .terminal, lines: ["$ echo zqxmarker", "zqxmarker"])], unreadable: false))
        while reader.state.value.documents[0].texts.isEmpty { await Task.yield() }
        let state = reader.state
        #expect(!state.complete)
        let found = await state.value.hits(["zqxmarker"])
        #expect(found.hits.map(\.tabID) == ["fast"])
        #expect(found.hits.first?.line == "zqxmarker")
    }

    @Test func noMatchesWaitsForTheLastRead() async {
        let sources = [Self.source("a", "build"), Self.source("b", "deploy")]
        let (reads, feed) = AsyncStream.makeStream(of: GlobalSearchCorpus.Read.self, bufferingPolicy: .bufferingOldest(2))
        let reader = GlobalSearchReader(sources, reads: reads)
        defer { reader.release() }
        let byTab: [String: GlobalSearchPage.Tab] = [:]

        // While reading, a query with no hit yet shows no "No matches" row.
        let reading = GlobalSearchPage.items([], limited: false, unreadable: 0, words: ["zqx"], byTab: byTab, reading: true,
                                             reveal: { _, _ in }, done: {})
        #expect(reading.isEmpty)

        feed.yield(GlobalSearchCorpus.Read(index: 0, texts: [], unreadable: true))
        feed.finish()
        let rows = await Self.answer("zqx", reader) { items in items.contains { $0.id == "globalSearch.notice.none" } }
        #expect(Self.ids(rows) == ["globalSearch.notice.none", "globalSearch.notice.unreadable"])
        #expect(reader.state.complete)
    }
}
