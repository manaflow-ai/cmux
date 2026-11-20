import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Review 2 of #28090 (issuecomment-6542219906): a contributed page that answers its own queries
/// (`PalettePageSpec.queryResults`, the agent chats page asks acpmux) joined into Search and the
/// Chats & agents scope. Its answers land in later turns than the ranked rows; these pin what the
/// person sees and what Return runs when they do.
@MainActor
@Suite(.paletteRanker, .closesItsWindows, .timeLimit(.minutes(1)))
struct ContributedAnswersTests {
    /// The chats contribution: each query's stream, answered when the test says (or at once).
    @MainActor final class Chats {
        var streams: [String: AsyncStream<[PaletteItem]>.Continuation] = [:]
        var asked: [String] = []
        /// Answer every query at once with these rows (acpmux had the query's window already).
        var immediate: [PaletteItem]?

        func results(_ query: String) -> AsyncStream<[PaletteItem]> {
            asked.append(query)
            let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
            if let immediate {
                continuation.yield(immediate)
                continuation.finish()
            } else {
                streams[query] = continuation
            }
            return stream
        }

        /// acpmux has no answer for `query` (disconnected or refused): its stream ends with no rows.
        func refuse(_ query: String) async {
            await ContributedAnswersTests.until { self.streams[query] != nil }
            streams[query]?.finish()
        }

        /// acpmux answers `query` with `rows`, and the query's stream ends (the chats page's one answer).
        /// The palette may ask in a later turn than the key's: this waits for the ask first.
        func answer(_ query: String, _ rows: [PaletteItem]) async {
            await ContributedAnswersTests.until { self.streams[query] != nil }
            streams[query]?.yield(rows)
            streams[query]?.finish()
        }
    }

    static func item(_ id: String, _ title: String, ran: Ran) -> PaletteItem {
        PaletteItem(id: id, title: title,
                    primary: PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform { ran.ids.append(id) }))
    }

    @MainActor final class Ran { var ids: [String] = [] }

    /// Search with a history page (section order 40, above the chats' 30) and the chats contribution.
    static func palette(chats: Chats, ran: Ran, extraHistory: [PaletteItem] = []) -> (PaletteController, ActionRegistry) {
        _ = NSApplication.shared
        var sources = PaletteSources()
        let history = [item("history:quokka", "Quokka notes", ran: ran), item("history:zebra", "Zebra wiki", ran: ran),
                       item("session:wombat", "Wombat session", ran: ran)] + extraHistory
        sources.searchContributions = [
            PaletteSearchContribution(id: "agentChats", title: "Agent Chats", order: 30, searchesChats: true) {
                Self.chatsPage(chats)
            },
            PaletteSearchContribution(id: "history", title: "History", order: 40, searchesChats: true) {
                PalettePageSpec(id: "history.search", title: "History", placeholder: "",
                                providers: [StaticPaletteProvider(id: "history.search", items: history)])
            },
        ]
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        palette.bindRegistryActions()
        return (palette, registry)
    }

    /// The chats page as Search contributes it: its own query, and the row Search shows when it cuts the answer.
    static func chatsPage(_ chats: Chats, initialQuery: String = "") -> PalettePageSpec {
        var page = PalettePageSpec(id: "agentChats", title: "Agent Chats", placeholder: "", providers: [],
                                   initialQuery: initialQuery, queryResults: { chats.results($0) }, filtersByQuery: false)
        page.moreRow = { notShown, query in
            PaletteItem(id: "agentChats.moreInSearch", title: "\(notShown) more matching chats",
                        primary: PaletteCommand(id: "open", title: "Open", symbol: "return",
                                                effect: .push(Self.chatsPage(chats, initialQuery: query))))
        }
        return page
    }

    /// Waits until `check` holds (an answer lands on a later main-actor turn), or gives up.
    static func until(_ check: () -> Bool) async {
        for _ in 0..<500 where !check() { await Task.yield() }
    }

    /// F1: acpmux answers the new query before its rank lands. The old query's ranked rows must not
    /// stand as the new query's final rows: a Return pressed at once runs the new query's best row.
    @Test func aReturnBeforeTheRankRunsTheNewQuerysBestRow() async {
        let chats = Chats(), ran = Ran()
        chats.immediate = [Self.item("chat:any", "Some chat", ran: ran)]
        let (palette, registry) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("zebra"))
        await palette.model.settle()
        await Self.until { palette.model.rows.contains { $0.id == "chat:any" } }
        palette.model.send(.setQuery("quokka"))
        palette.model.send(.activate(nil))
        await palette.model.settle()
        await Self.until { !ran.ids.isEmpty }
        #expect(ran.ids == ["history:quokka"], "Return ran \(ran.ids), not the new query's best row")
    }

    /// F2: the chats answer lands after the ranked rows, whose best match is in a section ordered after
    /// the chats (History, 40). The selected best row stays the first row on screen.
    @Test func aLateAnswerDoesNotPushTheSelectedBestRowDown() async {
        let chats = Chats(), ran = Ran()
        let (palette, registry) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("quokka"))
        await palette.model.settle()
        #expect(palette.model.selectedRowID == "history:quokka")
        await chats.answer("quokka", (0..<5).map { Self.item("chat:\($0)", "Quokka chat \($0)", ran: ran) })
        await Self.until { palette.model.rows.contains { $0.id == "chat:0" } }
        #expect(palette.model.rows.contains { $0.id == "chat:0" }, "the chats show")
        #expect(palette.model.selectedRowID == "history:quokka")
        #expect(palette.model.rows.first?.id == palette.model.selectedRowID,
                "the selected best row stays first: \(palette.model.rows.map(\.id))")
    }

    /// F2: the next key keeps the chats on screen until the new query's answer replaces them (no block
    /// that drops out and comes back at each key).
    @Test func theChatsStayUntilTheNextAnswerReplacesThem() async {
        let chats = Chats(), ran = Ran()
        let (palette, registry) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("quokka"))
        await palette.model.settle()
        await chats.answer("quokka", [Self.item("chat:old", "Quokka chat", ran: ran)])
        await Self.until { palette.model.rows.contains { $0.id == "chat:old" } }
        palette.model.send(.setQuery("quokka n"))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.id == "chat:old" }, "rows: \(palette.model.rows.map(\.id))")
        await chats.answer("quokka n", [Self.item("chat:new", "Quokka new chat", ran: ran)])
        await Self.until { palette.model.rows.contains { $0.id == "chat:new" } }
        #expect(!palette.model.rows.contains { $0.id == "chat:old" }, "the new answer replaces the old one")
    }

    /// F3: in the Chats & agents scope the chats are the page's main content. A Return pressed before
    /// acpmux answers runs the best chat once it lands, as the chats page itself does.
    @Test func aReturnInTheChatsScopeWaitsForTheChats() async {
        let chats = Chats(), ran = Ran()
        let (palette, _) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = palette.show(scope: PaletteScopeID.chats)
        await palette.model.settle()
        palette.model.send(.setQuery("wombat"))
        palette.model.send(.activate(nil))
        await palette.model.settle()
        await Self.until { chats.streams["wombat"] != nil }
        #expect(ran.ids.isEmpty, "nothing runs before the chats answer: \(ran.ids)")
        await chats.answer("wombat", [Self.item("chat:wombat", "Wombat chat", ran: ran)])
        await Self.until { !ran.ids.isEmpty }
        #expect(ran.ids == ["chat:wombat"], "Return ran \(ran.ids)")
    }

    /// Review 3 F1 ("flak" then "flaw", here words no command or row matches): "zqxjk" lists a chat; "zqxjw"
    /// matches nothing ranked. The old query's chat stays on screen
    /// only as a stand-in: a Return before acpmux answers "zqxjw" does not open it, and waits for the answer.
    @Test func anOldQuerysChatIsNeverTheNewQuerysReturn() async {
        let chats = Chats(), ran = Ran()
        let (palette, registry) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("zqxjk"))
        await palette.model.settle()
        await chats.answer("zqxjk", [Self.item("chat:flaky", "Zqxjk flaky test", ran: ran)])
        await Self.until { palette.model.rows.contains { $0.id == "chat:flaky" } }
        palette.model.send(.setQuery("zqxjw"))
        await palette.model.settle()
        palette.model.send(.activate(nil))
        await palette.model.settle()
        await Self.until { chats.streams["zqxjw"] != nil }
        #expect(ran.ids.isEmpty, "Return ran \(ran.ids) before acpmux answered the new query")
        await chats.answer("zqxjw", [Self.item("chat:flaw", "Zqxjw parser flaw", ran: ran)])
        await Self.until { !ran.ids.isEmpty }
        #expect(ran.ids == ["chat:flaw"], "Return ran \(ran.ids)")
    }

    /// Review 3 F1: acpmux gives no answer for the new query (disconnected or refused): the old query's chats
    /// leave the screen, they do not stay under later queries.
    @Test func noAnswerClearsTheOldQuerysChats() async {
        let chats = Chats(), ran = Ran()
        let (palette, registry) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("zqxjk"))
        await palette.model.settle()
        await chats.answer("zqxjk", [Self.item("chat:flaky", "Zqxjk flaky test", ran: ran)])
        await Self.until { palette.model.rows.contains { $0.id == "chat:flaky" } }
        palette.model.send(.setQuery("zqxjw"))
        await palette.model.settle()
        await chats.refuse("zqxjw")
        await Self.until { !palette.model.rows.contains { $0.id == "chat:flaky" } }
        #expect(!palette.model.rows.contains { $0.id == "chat:flaky" }, "rows: \(palette.model.rows.map(\.id))")
    }

    /// Review 3 F2: a one-letter query whose ranked rows fill the page's 400 still shows the best chats.
    @Test func aShortQueryThatFillsThePageStillShowsTheBestChats() async {
        let chats = Chats(), ran = Ran()
        let many = (0..<450).map { Self.item("history:a\($0)", "a page \($0)", ran: ran) }
        let (palette, registry) = Self.palette(chats: chats, ran: ran, extraHistory: many)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("a"))
        await palette.model.settle()
        await chats.answer("a", (0..<3).map { Self.item("chat:a\($0)", "a chat \($0)", ran: ran) })
        await Self.until { palette.model.rows.contains { $0.id == "chat:a0" } }
        let ids = palette.model.rows.map(\.id)
        #expect(ids.contains("chat:a0") && ids.contains("chat:a2"), "the best chats show: \(ids.filter { $0.hasPrefix("chat:") })")
        #expect(ids.count <= PaletteContributedAnswers.pageRowLimit, "\(ids.count) rows")
    }

    /// Review 3 M1: in the Chats & agents scope acpmux gives no answer (disconnected or refused): Return runs the
    /// best ranked row (the agent session) at once, it does not wait for chats that will not come.
    @Test func theChatsScopesReturnRunsTheBestSessionWhenAcpmuxDoesNotAnswer() async {
        let chats = Chats(), ran = Ran()
        let (palette, _) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = palette.show(scope: PaletteScopeID.chats)
        await palette.model.settle()
        palette.model.send(.setQuery("wombat"))
        palette.model.send(.activate(nil))
        await palette.model.settle()
        await chats.refuse("wombat")
        await Self.until { !ran.ids.isEmpty }
        #expect(ran.ids == ["session:wombat"], "Return ran \(ran.ids)")
    }

    /// Review 4 F1 (a): 30 matching chats on a Search page with room all show; none is cut.
    @Test func thirtyChatsOnAPageWithRoomAllShow() async {
        let chats = Chats(), ran = Ran()
        let (palette, registry) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("quokka"))
        await palette.model.settle()
        await chats.answer("quokka", (0..<30).map { Self.item("chat:\($0)", "Quokka chat \($0)", ran: ran) })
        await Self.until { palette.model.rows.contains { $0.id == "chat:0" } }
        let shown = palette.model.rows.map(\.id).filter { $0.hasPrefix("chat:") }
        #expect(shown.count == 30, "\(shown.count) of 30 chats show")
        #expect(!palette.model.rows.contains { $0.id == "agentChats.moreInSearch" }, "nothing is cut, so no more row")
    }

    /// Review 4 F1 (b): a one-letter query whose ranked rows fill the page shows the best 10 chats and the row that
    /// says how many more match; that row opens the chats page with the same query.
    @Test func aFullPageShowsTheBestTenChatsAndTheMoreRow() async {
        let chats = Chats(), ran = Ran()
        let many = (0..<450).map { Self.item("history:a\($0)", "a page \($0)", ran: ran) }
        let (palette, registry) = Self.palette(chats: chats, ran: ran, extraHistory: many)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("a"))
        await palette.model.settle()
        await chats.answer("a", (0..<25).map { Self.item("chat:a\($0)", "a chat \($0)", ran: ran) })
        await Self.until { palette.model.rows.contains { $0.id == "agentChats.moreInSearch" } }
        let ids = palette.model.rows.map(\.id)
        #expect(ids.filter { $0.hasPrefix("chat:") } == (0..<10).map { "chat:a\($0)" }, "\(ids.filter { $0.hasPrefix("chat:") })")
        let more = palette.model.rows.first { $0.id == "agentChats.moreInSearch" }
        #expect(more?.item.title == "15 more matching chats", "\(more?.item.title ?? "no more row")")
        #expect(ids.count <= PaletteContributedAnswers.pageRowLimit, "\(ids.count) rows")
        palette.model.send(.activate("agentChats.moreInSearch"))
        // Not settle(): the opened page's own query waits for an answer this test never gives.
        await Self.until { palette.model.pageTitle == "Agent Chats" }
        #expect(palette.model.pageTitle == "Agent Chats", "the more row opens the chats page: \(palette.model.pageTitle)")
        #expect(palette.model.query == "a", "with the same query: \(palette.model.query)")
    }

    /// Review 4 note 4: on a full page that still shows an older query's chats, End moves to the last row navigation
    /// may select (a ranked row), never onto a stand-in it cannot select.
    @Test func endNeverStopsOnAStandIn() async {
        let chats = Chats(), ran = Ran()
        let many = (0..<450).map { Self.item("history:a\($0)", "a page \($0)", ran: ran) }
        let (palette, registry) = Self.palette(chats: chats, ran: ran, extraHistory: many)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("a"))
        await palette.model.settle()
        await chats.answer("a", (0..<5).map { Self.item("chat:a\($0)", "a chat \($0)", ran: ran) })
        await Self.until { palette.model.rows.contains { $0.id == "chat:a0" } }
        palette.model.send(.setQuery("a "))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.id == "chat:a0" }, "the old chats stand in")
        let first = palette.model.selectedRowID
        _ = palette.model.handle(.moveToLast)
        // The last selectable row: a ranked row, not the first one (a refused move onto a stand-in leaves it there).
        #expect(palette.model.selectedRowID != first, "End did not move: \(palette.model.selectedRowID ?? "nil")")
        #expect(palette.model.selectedRowID?.hasPrefix("history:") == true, "selected: \(palette.model.selectedRowID ?? "nil")")
    }

    /// Review 5 F2: an answer that changes nothing on screen (an empty answer, no stand-ins) delivers nothing: no
    /// list reload, no reducer pass.
    @Test func anEmptyAnswerDeliversNothing() async {
        let chats = Chats(), ran = Ran()
        let (palette, registry) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("quokka"))
        await palette.model.settle()
        await Self.until { chats.streams["quokka"] != nil }
        let version = palette.model.resultsVersion
        await chats.refuse("quokka")
        for _ in 0..<50 { await Task.yield() }
        #expect(palette.model.resultsVersion == version, "an empty answer redelivered \(palette.model.resultsVersion - version) times")
    }

    /// Review 6 of #28090: the skip of a delivery that changes nothing compares what a delivery shows, not only the
    /// row ids. An answer with the same chats under new titles (a chat renamed) must reach the screen.
    @Test func anAnswerWithTheSameRowsRetitledIsDelivered() async {
        let chats = Chats(), ran = Ran()
        let (palette, registry) = Self.palette(chats: chats, ran: ran)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("quokka"))
        await palette.model.settle()
        await Self.until { chats.streams["quokka"] != nil }
        chats.streams["quokka"]?.yield([Self.item("chat:q", "Quokka plan", ran: ran)])
        await Self.until { palette.model.rows.contains { $0.id == "chat:q" } }
        #expect(palette.model.rows.first { $0.id == "chat:q" }?.item.title == "Quokka plan")
        // The stream reads on (no end in between), so nothing but the title changes.
        chats.streams["quokka"]?.yield([Self.item("chat:q", "Quokka plan, renamed", ran: ran)])
        await Self.until { palette.model.rows.first { $0.id == "chat:q" }?.item.title == "Quokka plan, renamed" }
        #expect(palette.model.rows.first { $0.id == "chat:q" }?.item.title == "Quokka plan, renamed",
                "the renamed chat's answer was skipped as unchanged")
        chats.streams["quokka"]?.finish()
    }

    /// Review 5 note 3: on a full page that shows an older query's chats, navigation's rows are the rows on screen
    /// (the shown and selectable lists cut the ranked rows at the same row), so the selection is never off screen.
    @Test func navigationRowsAreAllOnScreenWithStandIns() async {
        let chats = Chats(), ran = Ran()
        let many = (0..<450).map { Self.item("history:a\($0)", "a page \($0)", ran: ran) }
        let (palette, registry) = Self.palette(chats: chats, ran: ran, extraHistory: many)
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("a"))
        await palette.model.settle()
        await chats.answer("a", (0..<5).map { Self.item("chat:a\($0)", "a chat \($0)", ran: ran) })
        await Self.until { palette.model.rows.contains { $0.id == "chat:a0" } }
        palette.model.send(.setQuery("a "))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.id == "chat:a0" }, "the old chats stand in")
        let shown = Set(palette.model.rows.map(\.id))
        let offScreen = (palette.model.nav.top?.rows ?? []).map(\.id).filter { !shown.contains($0) }
        #expect(offScreen.isEmpty, "navigation rows not on screen: \(offScreen.prefix(5))")
    }
}
