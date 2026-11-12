import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileLive
import CmuxMobileTransport
import Foundation
import Testing

// The instant-list bench (Leo, 2026-11-10: "to load in my God sessions, it needs to be the exact
// same, or I mean, close enough to the exact same as the small sessions"). Each test measures one
// metric on the SMALL and the GOD fixture (InstantPerfFixtures.swift) side by side, reports it
// (`INSTANTPERF {json}`, InstantPerfReport.swift) and asserts its budget (3x target) and the
// ratio rule (god at most 1.2x max(small, 1 ms)). Red on base where declared `knownRed`.
//
// a. home_list_first_screen   the first window's `home-inbox` reply bytes (what a windowing host
//                              sends: 20 rows and the list's total) to the list the first screen
//                              draws (`MacHomeReply`, `MacHomeList`). Lists of 20 vs 5,000 rows. 16 ms.
// b. home_list_one_row_update  one row changes in a list of N: the `ids` read's reply parsed, put in
//                              place (`MacHomeRows.apply`) and the list patched (`MacHomeList.Memo`). 4 ms.
// c. chat_open_last_messages   open a chat on a fake acpmux until `AgentChatStore` holds the
//                              newest turn, finished. ~40 vs 50,000 records. 150 ms.
// d. chat_reconnect_catch_up   reattach after missing 10 vs 20,000 records until the store shows
//                              the newest turn (tail-first: the gap fills after, untimed). 150 ms.
// e. chat_older_page           one scroll-up page of older history. 50 ms.
//
// The suite is serialized and CI runs this target on its own (no other suite on the cores).
// Numbers are from a Debug build (`swift test`, `xcodebuild test`), as the kit's tests build.
//
// Run: swift test --package-path cmux-next-ios/CmuxMobileKit --filter CmuxMobileInstantPerfTests
//      CMUX_INSTANT_PERF_OUT=/tmp/instant-perf.jsonl adds a JSONL report; CMUX_INSTANT_PERF_RUNS=N
//      changes the number of measured runs (default 5, after one warm-up).
// Docs: cmux-next-ios/design/instant-perf.md

@MainActor
@Suite("Instant list perf: small vs god", .serialized)
struct InstantPerfTests {
    static let summary = AgentSessionSummary(id: "s7", name: "Fix", harness: "codex", agentName: "Codex", cwd: "/tmp/w",
                                             workspaceTitle: "w", macName: "mini")

    // MARK: Home list

    /// The `data` of a `home-inbox` reply line.
    static func inboxData(_ wire: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: wire) as? [String: Any]
        return object?["data"] as? [String: Any] ?? [:]
    }

    @Test("home_list_first_screen")
    func homeListFirstScreen() async throws {
        func firstScreen(_ size: InstantPerfSize) async throws -> [Double] {
            let wire = HomeInboxFixture.firstWindowWire(size)
            return try await InstantPerfReport.sample {
                var list: MacHomeList?
                var reply: MacHomeReply?
                let elapsed = try ContinuousClock().measure {
                    let read = try MacHomeReply(line: wire)
                    reply = read
                    list = MacHomeList(read.rows)
                }
                let shown = (list?.pinned.count ?? 0) + (list?.rows.count ?? 0)
                let count = HomeInboxFixture.rowCount(size)
                #expect(shown == min(count, MacHomeRows.firstWindow), "the first screen lost rows: \(shown)")
                if case .window(_, _, let total) = reply {
                    #expect(total == count, "the window does not know the list's size")
                } else {
                    Issue.record("not a window: \(String(describing: reply))")
                }
                return elapsed
            }
        }
        /// The whole list behind the first screen (one read, off the main actor in the app): reported, not timed against the target.
        func wholeList(_ size: InstantPerfSize) async throws -> Double {
            let wire = HomeInboxFixture.wire(size)
            return InstantPerfReport.median(try await InstantPerfReport.sample(runs: 3) {
                try ContinuousClock().measure { _ = MacHomeList(try MacHomeReply(line: wire).rows) }
            })
        }
        let small = try await firstScreen(.small)
        let god = try await firstScreen(.god)
        let godWhole = try await wholeList(.god)
        InstantPerfReport.record(
            "home_list_first_screen", target: 16, small: small, god: god,
            note: String(format: "first window %ld B (20 of 20 rows) vs %ld B (20 of 5,000 rows); the whole god list (%ld B) follows off the main actor: %.1f ms",
                         HomeInboxFixture.firstWindowWire(.small).count, HomeInboxFixture.firstWindowWire(.god).count,
                         HomeInboxFixture.wire(.god).count, godWhole))
    }

    @Test("home_list_one_row_update")
    func homeListOneRowUpdate() async throws {
        /// The rows before one conversation in the middle of the list changes in place (a Chief
        /// starts typing, a message is read, a mark is set), and the reply to the feed's `ids`
        /// read of it: that row alone at its index, and the list's total.
        func change(_ size: InstantPerfSize) -> (before: [MacHomeRow], id: String, reply: Data) {
            let wire = HomeInboxFixture.rows(size)
            let before = MacHomeRow.rows(fromHomeInbox: ["rows": wire])
            let mid = wire.count / 2
            var row = wire[mid]
            row["unread"] = ((row["unread"] as? Int) ?? 0) + 1
            row["preview"] = "Typing: the relay is back, 24 tests pass."
            row["index"] = mid
            return (before, before[mid].id, HomeInboxFixture.encode([row], ["total": wire.count]))
        }
        /// What the feed does on that change: the `ids` reply parsed, the row put in place in the
        /// feed's rows, and Home's list patched by the memo (keyed on the rows' revision).
        func update(_ size: InstantPerfSize) async throws -> (runs: [Double], memo: Double) {
            let fixture = change(size)
            var memoTimes: [Double] = []
            let runs = try await InstantPerfReport.sample {
                // The feed's own rows (not shared with the fixture, as the feed holds them).
                var rows = fixture.before.map { $0 }
                let memo = MacHomeList.Memo()
                _ = memo.list(rows, query: "", unreadOnly: false, version: .init(rows: 1))
                var list: MacHomeList?
                var memoTime = Duration.zero
                let elapsed = try ContinuousClock().measure {
                    guard case .named(let found, _, _) = try MacHomeReply(line: fixture.reply) else { return }
                    let inPlace = MacHomeRows.apply(found, asked: [fixture.id], complete: true, to: &rows)
                    let start = ContinuousClock.now
                    list = memo.list(rows, query: "", unreadOnly: false, version: .init(rows: 2),
                                     change: inPlace.map { MacHomeRows.Change(revision: 2, indices: $0) })
                    memoTime = start.duration(to: .now)
                }
                memoTimes.append(InstantPerfReport.ms(memoTime))
                #expect(memo.builds == 1 && memo.patches == 1, "the list was built again: \(memo.builds) builds")
                #expect(list?.rows.contains { $0.preview.hasPrefix("Typing:") } == true)
                #expect(rows.count == fixture.before.count)
                return elapsed
            }
            return (runs, InstantPerfReport.median(memoTimes))
        }
        let small = try await update(.small)
        let god = try await update(.god)
        InstantPerfReport.record(
            "home_list_one_row_update", target: 4, small: small.runs, god: god.runs,
            note: String(format: "row N/2 changes in place; timed: the ids read's reply (%ld B), the row put in place, the list patched. The memo alone: small %.3f ms, god %.3f ms",
                         change(.god).reply.count, small.memo, god.memo))
    }

    // MARK: Agent chat

    /// Waits, with the main actor free, until `done`, for at most `timeout`. Polls every 0.1 ms:
    /// fine enough for the targets, and leaves the cores to the work being timed.
    static func waitUntil(_ timeout: Duration = .seconds(120), _ done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .microseconds(100)) // test: polls the condition until a deadline
        }
        return true
    }

    /// The store shows `turn`, finished, with its items.
    static func shows(_ store: AgentChatStore, _ turn: String) -> Bool {
        guard let last = store.turns.last else { return false }
        return last.id == turn && last.status == .completed && !last.items.isEmpty
    }

    /// A hub bound to a fake acpmux over `fake`'s log (initialize and watch done: the link is up).
    static func boundHub(_ link: MockMacLink) async throws -> AcpmuxHub {
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        return hub
    }

    /// Opens the chat on a bound hub and waits for its newest turn (untimed setup for d and e).
    static func openedChat(_ fake: InstantPerfAcpmux, link: MockMacLink) async throws -> (AcpmuxHub, AgentChatStore) {
        let hub = try await boundHub(link)
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: summary))
        let newest = try #require(fake.log.lastTurn(before: fake.end))
        let shown = await waitUntil { shows(store, newest) }
        try #require(shown, "the chat never showed \(newest)")
        return (hub, store)
    }

    static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    @Test("chat_open_last_messages")
    func chatOpenLastMessages() async throws {
        func open(_ log: AgentChatLog) async throws -> [Double] {
            try await InstantPerfReport.sample {
                let fake = InstantPerfAcpmux(log)
                let hub = try await Self.boundHub(fake.link())
                let newest = try #require(log.lastTurn(before: log.count))
                let start = ContinuousClock.now
                let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
                let shown = await Self.waitUntil { Self.shows(store, newest) }
                let elapsed = start.duration(to: .now)
                #expect(shown, "the chat never showed its newest turn \(newest)")
                await hub.bind(nil)
                withExtendedLifetime(store) {}
                return elapsed
            }
        }
        let small = try await open(AgentChatFixture.small)
        let god = try await open(AgentChatFixture.god)
        InstantPerfReport.record(
            "chat_open_last_messages", target: 150, small: small, god: god,
            // Green on base: the open reads one byte-capped page, the newest, whatever the chat holds.
            note: "small \(AgentChatFixture.small.count) records (\(Self.mb(AgentChatFixture.small.totalBytes))) vs god \(AgentChatFixture.god.count) records (\(Self.mb(AgentChatFixture.god.totalBytes)))")
    }

    @Test("chat_reconnect_catch_up")
    func chatReconnectCatchUp() async throws {
        /// The chat opened on `log`'s first `cut` records, the link gone while the Mac wrote the
        /// rest, and the link back (`bind`, untimed here): until the newest turn shows.
        func reconnected(_ log: AgentChatLog, cut: Int) async throws -> (hub: AcpmuxHub, store: AgentChatStore, start: ContinuousClock.Instant, shown: Bool) {
            let newest = try #require(log.lastTurn(before: log.count))
            let fake = InstantPerfAcpmux(log, end: cut)
            let link = fake.link()
            let (hub, store) = try await Self.openedChat(fake, link: link)
            // The phone goes away; the Mac writes the rest of the log meanwhile.
            await hub.bind(nil)
            fake.end = log.count
            let start = ContinuousClock.now
            await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
            let shown = await Self.waitUntil { Self.shows(store, newest) }
            return (hub, store, start, shown)
        }
        func reconnect(_ log: AgentChatLog, missing: Int, runs: Int) async throws -> (runs: [Double], missed: Int, bytes: Int) {
            let cut = log.boundary(near: log.count - missing)
            let samples = try await InstantPerfReport.sample(runs: runs) {
                let run = try await reconnected(log, cut: cut)
                let elapsed = run.start.duration(to: .now)
                #expect(run.shown, "the chat never caught up to its newest turn")
                await run.hub.bind(nil)
                withExtendedLifetime(run.store) {}
                return elapsed
            }
            return (samples, log.count - cut, log.bytes[cut...].reduce(0, +))
        }
        /// After the newest turn showed, the gap fills in the background (untimed by the
        /// metric): how long it takes, and that every turn is then shown once, in order.
        func fill(_ log: AgentChatLog, missing: Int) async throws -> Double {
            let run = try await reconnected(log, cut: log.boundary(near: log.count - missing))
            #expect(run.shown)
            let filled = await Self.waitUntil { !run.store.isFillingGap }
            let elapsed = InstantPerfReport.ms(run.start.duration(to: .now))
            #expect(filled, "the gap never filled")
            let numbers = run.store.turns.compactMap { Int($0.id.dropFirst()) }
            #expect(numbers.count == run.store.turns.count)
            #expect(zip(numbers, numbers.dropFirst()).allSatisfy { $1 == $0 + 1 }, "turns missing, repeated or out of order after the gap filled")
            #expect(run.store.turns.last?.id == log.lastTurn(before: log.count))
            await run.hub.bind(nil)
            return elapsed
        }
        let small = try await reconnect(AgentChatFixture.small, missing: 10, runs: InstantPerfReport.defaultRuns)
        let god = try await reconnect(AgentChatFixture.god, missing: 20_000, runs: min(InstantPerfReport.defaultRuns, 3))
        let godFill = try await fill(AgentChatFixture.god, missing: 20_000)
        InstantPerfReport.record(
            "chat_reconnect_catch_up", target: 150, small: small.runs, god: god.runs,
            // Green since the tail-first reattach: a gap longer than one page reads the newest
            // page (as an open does) and one empty read after it, shows them, and fills the gap after.
            note: String(format: "missed \(small.missed) records (\(Self.mb(small.bytes))) vs \(god.missed) records (\(Self.mb(god.bytes))); timed from the link coming back (bind) to the newest turn shown. God's gap then filled in the background in %.0f ms (untimed)", godFill))
    }

    @Test("chat_older_page")
    func chatOlderPage() async throws {
        func older(_ log: AgentChatLog) async throws -> [Double] {
            try await InstantPerfReport.sample {
                let fake = InstantPerfAcpmux(log)
                let (hub, store) = try await Self.openedChat(fake, link: fake.link())
                try #require(store.hasEarlierHistory, "the open page reached the chat's start: no older page to read")
                let before = store.turns.count
                let start = ContinuousClock.now
                store.loadEarlier()
                let shown = await Self.waitUntil { !store.isLoadingEarlier && store.turns.count > before }
                let elapsed = start.duration(to: .now)
                #expect(shown, "the older page never showed")
                await hub.bind(nil)
                return elapsed
            }
        }
        // The ~40-record chat opens whole; the small case is a short chat just over one open page.
        let small = try await older(AgentChatFixture.smallPaged)
        let god = try await older(AgentChatFixture.god)
        InstantPerfReport.record(
            "chat_older_page", target: 50, small: small, god: god,
            knownRed: [.ratio],
            why: "an older page is up to 256 KiB of whole records (more when one record is larger), decoded and turned into turns before it shows",
            note: "small: \(AgentChatFixture.smallPaged.count)-record chat (one page over the open); god: \(AgentChatFixture.god.count) records")
    }
}
