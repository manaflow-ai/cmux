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
// f. chat_scroll_fill          a 60 Hz fling up a chat's history over a phone's link: p95 of each
//                              frame's time to a filled viewport. 16.7 ms (one frame).
// g. chat_scroll_fill_ui       the same fling on the transcript list itself (ChatScrollFillUITests.swift,
//                              iOS): its layout, cells and reloads, not estimated heights. 16.7 ms.
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
            // Green since the Mac cuts a page's oversized tool output (`toolOutputMaxBytes`,
            // OlderPageToolOutputTests): god's first older page carried a 2 MB log whole, about
            // 6 ms more on the wire and in the parse. Scrolling never waits for this read
            // (`chat_scroll_fill`: it runs four screens ahead).
            note: "small: \(AgentChatFixture.smallPaged.count)-record chat (one page over the open); god: \(AgentChatFixture.god.count) records")
    }

    // MARK: Scrolling up (chat_scroll_fill)

    /// The reader the fling moves: where it is, as the list knows it.
    struct FlingReader {
        /// The transcript's height on an iPhone, in points.
        static let viewport: Double = 800
        /// 60 Hz.
        static let frame: Duration = .microseconds(16_667)
        /// A flick's speed, and UIScrollView's normal deceleration (0.998 per ms); a person
        /// flicks again each time the list slows under `reflick`.
        static let flick: Double = 8_000
        static let decay: Double = 0.998
        static let reflick: Double = 1_000
        /// Frames in one fling (six seconds of flicking up).
        static let frames = 360
        /// The link: a relayed phone's round trip and throughput.
        static let rtt: Duration = .milliseconds(50)
        static let bytesPerSecond: Double = 4_000_000

        /// A turn's height as the list draws it, near enough for where its rows are: the prompt
        /// bubble, each message's lines (about 42 characters a line on a phone) and one row per
        /// tool call, plan or subagent (collapsed, as history shows them).
        static func height(_ turn: AgentTurn) -> Double {
            turn.items.reduce(96) { total, item in
                if case .message(_, let markdown) = item {
                    return total + 16 + 22 * (Double(markdown.utf8.count) / 42).rounded(.up)
                }
                return total + 52
            }
        }
    }

    /// What the list does on a scroll step (`ChatTranscriptList.scrollViewDidScroll`):
    /// `screensAbove` is how far the top of the viewport is below the oldest row shown, in
    /// screens. Within four, the page before it is asked for (``AgentChatStore/readAhead(screensAbove:)``).
    /// Before the read-ahead, the read started when the oldest row (`session-start`) drew,
    /// about 46 pt from the top: `if screensAbove * FlingReader.viewport < 46 { store.loadEarlier() }`.
    static func scrollStep(_ store: AgentChatStore, screensAbove: Double) {
        store.readAhead(screensAbove: screensAbove)
    }

    /// One fling up `log` from its newest turn: each 60 Hz frame moves the reader, tells the
    /// store (`scrollStep`) and is timed to a filled viewport: the step's own work, an older
    /// page landing on the main actor since the last frame, and, when the viewport passed the
    /// oldest row shown while the chat holds older ones (a blank or placeholder top), the wait
    /// for rows; every frame that passes during such a wait counts, at its own wait.
    static func fling(_ log: AgentChatLog) async throws -> (fills: [Double], blank: Int, pages: Int, screens: Double) {
        let fake = InstantPerfAcpmux(log)
        let hub = AcpmuxHub()
        await hub.bind(fake.channel(rtt: FlingReader.rtt, bytesPerSecond: FlingReader.bytesPerSecond))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: summary))
        let newest = try #require(log.lastTurn(before: log.count))
        let shown = await waitUntil { shows(store, newest) }
        try #require(shown, "the chat never showed \(newest)")
        defer { withExtendedLifetime(store) {} }

        let viewport = FlingReader.viewport
        var heights: [String: Double] = [:]
        func height(_ turn: AgentTurn) -> Double {
            if let known = heights[turn.id] { return known }
            let made = FlingReader.height(turn)
            heights[turn.id] = made
            return made
        }
        // At the newest turn: the content above the viewport's top.
        var above = max(store.turns.reduce(0) { $0 + height($1) } - viewport, 0)
        var oldest = store.turns.first?.id
        var pages = 0
        var landed = store.earlierApplyTime
        /// Older turns that went in above since the last look: the list keeps the reader's
        /// rows in place, so the reader is that much further from the top.
        func absorb() -> Double {
            guard let first = oldest, store.turns.first?.id != first,
                  let index = store.turns.firstIndex(where: { $0.id == first }) else { return 0 }
            above += store.turns[..<index].reduce(0) { $0 + height($1) }
            oldest = store.turns.first?.id
            pages += 1
            let applied = store.earlierApplyTime
            defer { landed = applied }
            return InstantPerfReport.ms(applied - landed)
        }
        // The list's first layout reports where the reader is; a person starts the fling a
        // moment after the chat shows.
        scrollStep(store, screensAbove: above / viewport)
        try await Task.sleep(for: .milliseconds(750)) // test: a person's pause before scrolling
        _ = absorb()

        var fills: [Double] = []
        var blank = 0
        var speed = FlingReader.flick
        var travelled = 0.0
        let frameMs = InstantPerfReport.ms(FlingReader.frame)
        let start = ContinuousClock.now
        var frame = 0
        while frame < FlingReader.frames {
            let due = start + FlingReader.frame * frame
            try await Task.sleep(until: due, clock: .continuous) // test: the display's next frame
            let woke = ContinuousClock.now
            let landing = absorb()
            // The frame's scroll: UIScrollView's deceleration over one frame.
            let step = speed * frameMs / 1_000
            speed *= pow(FlingReader.decay, frameMs)
            if speed < FlingReader.reflick { speed = FlingReader.flick }
            above -= step
            travelled += step
            scrollStep(store, screensAbove: max(above, 0) / viewport)
            if above >= 0 || !store.hasEarlierHistory {
                fills.append(InstantPerfReport.ms(woke.duration(to: .now)) + landing)
                if above < 0 { break } // the chat's start: the fling is over
                frame += 1
                continue
            }
            // The viewport passed the oldest row shown: until rows come, it is blank at the top.
            let came = await waitUntil(.seconds(30)) { store.turns.first?.id != oldest || !store.hasEarlierHistory }
            #expect(came, "the older page never came")
            let filled = ContinuousClock.now
            var waiting = frame
            while start + FlingReader.frame * waiting < filled {
                fills.append(InstantPerfReport.ms((start + FlingReader.frame * waiting).duration(to: filled)))
                blank += 1
                waiting += 1
            }
            // The list stopped at its top while it waited; the rows that came go in above it.
            above = max(above, 0)
            _ = absorb()
            if !came || above < 0 && !store.hasEarlierHistory { break }
            frame = waiting
        }
        await hub.bind(nil)
        return (fills, blank, pages, travelled / viewport)
    }

    static func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[max(Int((Double(sorted.count) * 0.95).rounded(.up)) - 1, 0)]
    }

    @Test("chat_scroll_fill")
    func chatScrollFill() async throws {
        func flings(_ log: AgentChatLog) async throws -> (p95s: [Double], blank: Int, pages: Int, screens: Double, worst: Double) {
            var blank = 0, pages = 0, screens = 0.0, worst = 0.0
            let p95s = try await InstantPerfReport.sample(runs: min(InstantPerfReport.defaultRuns, 3)) {
                let run = try await Self.fling(log)
                blank += run.blank
                pages += run.pages
                screens += run.screens
                worst = max(worst, run.fills.max() ?? 0)
                return .microseconds(Int64((Self.p95(run.fills) * 1_000).rounded()))
            }
            return (p95s, blank, pages, screens, worst)
        }
        let small = try await flings(AgentChatFixture.smallPaged)
        let god = try await flings(AgentChatFixture.god)
        let target = 16.7
        InstantPerfReport.record(
            "chat_scroll_fill", target: target, small: small.p95s, god: god.p95s,
            // Green since the read-ahead: the older read starts four screens before the top,
            // and the source holds the page after it, decoded.
            note: String(format: "p95 per fling of each 60 Hz frame's time to a filled viewport (%d frames, flicks of 8,000 pt/s, 800 pt viewport) over a %d ms, 4 MB/s link; frames with a blank top: small %d, god %d (warm-up included); pages shown: small %d, god %d; worst frame: small %.1f ms, god %.1f ms",
                         FlingReader.frames, 50, small.blank, god.blank, small.pages, god.pages, small.worst, god.worst))
        // The gate (Leo, 2026-11-12: "I don't ever want to be, like, waiting for it to load"):
        // one frame at p95 on both, and no frame with a blank top.
        let gate: () -> Void = {
            #expect(InstantPerfReport.median(small.p95s) <= target, "small's p95 frame is over one frame")
            #expect(InstantPerfReport.median(god.p95s) <= target, "god's p95 frame is over one frame")
            #expect(small.blank == 0 && god.blank == 0, "rows were blank while scrolling: small \(small.blank), god \(god.blank) frames")
        }
        gate()
    }
}
