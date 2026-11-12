import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextHistory
import CmuxNextHistoryDaemon
@testable import CmuxNextHistoryPages
import CmuxNextPages
@testable import CmuxNextPalette
import CmuxNextSettings
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// `history.entries.list` can answer before the daemon has folded the whole session journal: it gives
/// the entries it has and names the kinds that are not complete (`pending_kinds`, cmux#41639). The app
/// must not take that short list for the whole list: it says so and tells the History page.
@MainActor struct HistoryPendingReadTests {
    static let closed = HistoryEntry(id: "closed:daemon:closed_1", kind: .closed, time: Date(), title: "build",
                                     payload: .closed(CmuxNextHistory.ClosedItem(id: "daemon:closed_1", kind: .terminalTab, title: "build", machine: "local")))

    @Test func theListDecodesItsPendingKinds() throws {
        let partial = try JSONDecoder().decode(DaemonHistoryList.self,
                                               from: Data(#"{"entries":[],"revision":"3","pending_kinds":["agent","a-later-kind"]}"#.utf8))
        #expect(partial.pendingKinds == [.agent], "a kind this build does not know is left out, not a decode failure")
        let whole = try JSONDecoder().decode(DaemonHistoryList.self, from: Data(#"{"entries":[],"revision":"3"}"#.utf8))
        #expect(whole.pendingKinds.isEmpty)
    }

    @Test func aListThatIsNotCompleteSaysItIsStillLoading() throws {
        let agents = HistoryQuery(kinds: [.agent])
        let status = try #require(HistoryRead(entries: [], pending: [.agent]).status(agents), "an empty pending list read as nothing there")
        #expect(status.id == "history.status.pending")
        #expect(!status.canRetry, "the list reads again by itself")
        #expect(!HistoryPalettePages.statusItem(status).isEnabled)
        // The rows that came are shown, and the list still says more is to come.
        #expect(HistoryRead(entries: [Self.closed], pending: [.agent]).status(HistoryQuery())?.id == "history.status.pending")
        // A search, too: its "No Results" would be wrong while the kind is not complete.
        #expect(HistoryRead(entries: [], pending: [.agent]).status(HistoryQuery(text: "zzz", kinds: [.agent]))?.id == "history.status.pending")
        // An owner that did not answer is the stronger fact (Try Again).
        #expect(HistoryRead(entries: [], unavailable: true, pending: [.agent]).status(agents)?.id == "history.status.unavailable")
        // A complete list is as before.
        #expect(HistoryRead(entries: [Self.closed]).status(HistoryQuery()) == nil)
        #expect(HistoryRead(entries: []).status(HistoryQuery(kinds: [.closed]))?.id == "history.status.empty")
    }

    /// The app's History owner as the page reaches it, answering `answer`.
    final class Owner: HistoryPageEditing {
        var answer = HistoryRead(entries: [])
        func read(_ query: HistoryQuery) async -> HistoryRead { answer }
        func entry(id: String) async -> HistoryEntry? { nil }
        func remove(_ entry: HistoryEntry) {}
        func removePages(host: String) {}
        func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange) {}
    }

    final class Relay: PageProvider {
        func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue { .object([:]) }
    }

    @Test func theHistoryPageIsToldWhichKindsAreNotComplete() async throws {
        let owner = Owner(), relay = Relay()
        let provider = HistoryCookieBackupsPageProvider { nil }
        provider.relay = relay
        provider.history = owner
        let context = PageCallContext(page: "cmux.history")
        owner.answer = HistoryRead(entries: [Self.closed], pending: [.agent])
        let partial = try await provider.call("cmux.history.entries.list", params: .object([:]), context: context)
        #expect(partial["entries"]?.arrayValue?.count == 1)
        #expect(partial["pending_kinds"]?.arrayValue?.compactMap(\.stringValue) == ["agent"])
        owner.answer = HistoryRead(entries: [Self.closed])
        let whole = try await provider.call("cmux.history.entries.list", params: .object([:]), context: context)
        #expect(whole["pending_kinds"] == nil, "a complete list names no pending kind")
        // The provider holds its owner weakly.
        withExtendedLifetime((owner, relay)) {}
    }

    /// `history.open` by an id no open page shows (`cmux history open`): an id that is not in a list
    /// that is not complete is not known yet. The answer is "still loading" at once (the action does
    /// not wait), never "that entry is gone".
    @Test func anEntryThatIsNotListedYetIsNotGone() throws {
        let row = DaemonHistoryEntry(id: "agent:local:listed", kind: .agent, atMS: 1, title: "listed", available: true)
        let partial = DaemonHistoryList(entries: [row], pendingKinds: [.agent])
        #expect(partial.isStillLoading(id: "agent:local:not-yet"))
        #expect(!partial.isStillLoading(id: "agent:local:listed"), "a listed entry is known")
        #expect(!partial.isStillLoading(id: "page:default:7"), "only the pending kind is not complete")
        #expect(!DaemonHistoryList(entries: [row]).isStillLoading(id: "agent:local:not-yet"), "a complete list knows the entry is gone")

        guard case .failure(let refusal) = HistoryLookup.stillLoading.opening else {
            Issue.record("an entry that is not listed yet opened")
            return
        }
        #expect(refusal.refusal == .unavailable, "a caller can ask again: the entry is not gone")
        #expect(refusal.message == HistoryAppStrings.stillLoading)
        #expect(refusal.message != HistoryAppStrings.entryGone)
        guard case .failure(let gone) = HistoryLookup.gone.opening else {
            Issue.record("a gone entry opened")
            return
        }
        #expect(gone.message == HistoryAppStrings.entryGone)
        guard case .success(let opened) = HistoryLookup.found(Self.closed).opening else {
            Issue.record("a found entry did not open")
            return
        }
        #expect(opened.id == Self.closed.id)
    }
}

/// The palette's History lists read a list that is not complete again by themselves: after 1 s, 2 s,
/// 4 s, then each 8 s (an async clock sleep, never a loop on the main thread), until the list is
/// complete or the person leaves the page.
@MainActor @Suite(.serialized) struct HistoryPendingPaletteTests {
    /// Reads answered in order; the last answer repeats.
    final class Reads {
        var answers: [HistoryRead]
        var count = 0
        init(_ answers: [HistoryRead]) { self.answers = answers }
        func next() -> HistoryRead {
            defer { count += 1 }
            return answers[min(count, answers.count - 1)]
        }
    }

    static func row(_ id: String) -> PaletteItem {
        PaletteItem(id: id, title: id, primary: PaletteCommand(id: "open", title: "Open", effect: .performKeepingOpen {}))
    }

    /// A History list as `HistoryPalettePages` builds it: the entries' rows, then the status row.
    static func provider(_ reads: Reads, clock: ManualClock) -> AsyncPaletteProvider {
        AsyncPaletteProvider.rereading(id: "history.agents", read: {
            let read = reads.next()
            let rows = read.entries.map { row($0.id) } + (read.status(HistoryQuery(kinds: [.agent])).map { [HistoryPalettePages.statusItem($0)] } ?? [])
            return (rows, !read.pending.isEmpty)
        }, wait: { try await DaemonHistoryClient.waitForPending(afterReads: $0, clock: clock) })
    }

    @Test(.timeLimit(.minutes(1))) func aListThatIsNotCompleteIsReadAgainAfter1_2_4_8SecondsUntilItIs() async throws {
        let clock = ManualClock()
        let partial = HistoryRead(entries: [], pending: [.agent])
        let reads = Reads([partial, partial, partial, partial, partial, HistoryRead(entries: [HistoryPendingReadTests.closed])])
        var lists = try #require(Self.provider(reads, clock: clock).itemUpdates()).makeAsyncIterator()
        let first = await lists.next()
        #expect(first?.map(\.id) == ["history.status.pending"], "the first list shows at once, with its sign")
        for (index, seconds) in [1, 2, 4, 8, 8].enumerated() {
            try await clock.waitForSleeper()
            #expect(clock.sleeperDeadlines.map { clock.now.duration(to: $0) } == [.seconds(seconds)], "wait \(index + 1)")
            #expect(reads.count == index + 1, "no read while the wait runs")
            clock.advance(by: .seconds(seconds))
            let list = await lists.next()
            #expect(list?.map(\.id) == (index < 4 ? ["history.status.pending"] : [HistoryPendingReadTests.closed.id]))
        }
        let end = await lists.next()
        #expect(end == nil, "a complete list ends the reads")
        #expect(reads.count == 6)
        #expect(clock.sleeperCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func theReadsStopWhenThePersonLeavesThePage() async throws {
        let clock = ManualClock()
        let reads = Reads([HistoryRead(entries: [], pending: [.agent])])
        let updates = try #require(Self.provider(reads, clock: clock).itemUpdates())
        // The palette reads a page's updates in a task of the page and cancels it when the page goes.
        let page = Task { @MainActor in
            var shown = 0
            for await _ in updates { shown += 1 }
            return shown
        }
        try await clock.waitForSleeper()
        page.cancel()
        let shown = await page.value
        #expect(shown == 1)
        #expect(clock.sleeperCount == 0, "the wait ended with the page")
        clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(reads.count == 1, "no read after the person left")
    }

    @Test(.timeLimit(.minutes(1))) func aHeadlessReadOfTheListDoesNotWaitForTheRest() async {
        let reads = Reads([HistoryRead(entries: [], pending: [.agent])])
        let rows = await Self.provider(reads, clock: ManualClock()).items()
        #expect(rows.map(\.id) == ["history.status.pending"])
        #expect(reads.count == 1)
    }

    /// Search lists History through its own wrapper: it must pass each list on as it comes, else Search
    /// would show nothing until the list is complete.
    @Test(.timeLimit(.minutes(1))) func searchShowsEachListOfAHistoryKindAsItComes() async throws {
        let clock = ManualClock()
        let reads = Reads([HistoryRead(entries: [], pending: [.agent]), HistoryRead(entries: [HistoryPendingReadTests.closed])])
        let section = PaletteSection(id: "search.history.agents", title: "Agent Sessions", order: 43)
        let wrapper = PaletteSearchSectionedProvider(Self.provider(reads, clock: clock), id: "search.history.agents.history.agents", section: section)
        var lists = try #require(wrapper.itemUpdates(), "Search waits for the end of the History reads").makeAsyncIterator()
        let first = await lists.next()
        #expect(first?.map(\.id) == ["history.status.pending"])
        #expect(first?.map(\.section.id) == [section.id])
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        let second = await lists.next()
        #expect(second?.map(\.id) == [HistoryPendingReadTests.closed.id])
        #expect(second?.map(\.section.id) == [section.id])
        let end = await lists.next()
        #expect(end == nil)
    }

    /// The five History pages and Search's four History sections are built by one function: its provider gives updates.
    @Test func thePalettesHistoryListsGiveUpdates() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        for page in [HistoryPalettePages.agents(services), HistoryPalettePages.closed(services)] {
            let provider = try #require(page.providers.first)
            #expect(provider.itemUpdates() != nil, "\(page.id) reads one time only")
        }
        let search = try #require(HistoryPalettePages.searchContributions(services).first { $0.id == "history.agents" }?.page())
        #expect(search.providers.first?.itemUpdates() != nil)
    }
}
