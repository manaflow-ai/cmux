import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Latest screen first (cmuxterm-hq#7231, design/ios.md S15): against a daemon
/// with `attach-replay-history-rows-v1` the attach asks for the screen alone,
/// and older rows come only when the reader scrolls up to them, in bounded
/// chunks, without the terminal ever leaving the attached state. An older
/// daemon, or a lane that refuses the field, gets today's whole replay.
@MainActor @Suite struct DaemonTerminalHistoryTests {
    private func session(_ daemon: FakeTerminalDaemon, _ channels: ChannelLog) -> DaemonTerminalSession {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        return DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
    }

    private func attaches(_ daemon: FakeTerminalDaemon) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }
    }

    private func text(_ events: [TerminalSessionEvent]) -> String {
        events.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
    }

    @Test func theFirstAttachAsksForTheScreenAlone() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.historyRows = 9_000
        daemon.afterAttach = nil
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached && session.historyRowsOmitted == 9_000 && text(events).hasSuffix("$ ") }
        #expect(attaches(daemon).first?["replay_history_rows"] as? Int == 0)
        #expect(session.historyRowsOmitted == 9_000)
        #expect(text(events) == "\u{1B}c[0 rows]hello\r\n$ ")
    }

    @Test func anOlderDaemonGetsTheWholeReplayAndNoHistoryFetch() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.historyRows = 9_000
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        #expect(attaches(daemon).count == 1)
        #expect(attaches(daemon).first?["replay_history_rows"] == nil)
        #expect(session.historyRowsOmitted == 0)
        session.loadOlderHistory()
        try await Task.sleep(for: .milliseconds(100))
        #expect(attaches(daemon).count == 1, "nothing to fetch: the mirror has the whole history")
    }

    @Test func aLaneThatRefusesTheFieldGetsTheSameAttachWithoutIt() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.laneRefusesHistoryRows = true
        daemon.historyRows = 9_000
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let sent = attaches(daemon)
        #expect(sent.count == 2)
        #expect(sent.first?["replay_history_rows"] as? Int == 0)
        #expect(sent.last?["replay_history_rows"] == nil)
        #expect(session.historyRowsOmitted == 0)
    }

    /// Scrolling up to the oldest row fetches the next chunk on a second
    /// attach that replaces the first: the mirror resets and replays the
    /// screen with more history, the old attach releases its size and
    /// closes, and the screen is never told the terminal left.
    @Test func olderRowsComeInChunksWhileTheTerminalStaysAttached() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.historyRows = 3_500
        daemon.afterAttach = nil
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        events.removeAll()

        session.loadOlderHistory()
        // Asked again while the first fetch is out: one fetch only.
        session.loadOlderHistory()
        try await waitUntil { session.historyRowsOmitted == 1_500 }
        #expect(attaches(daemon).count == 2)
        #expect(attaches(daemon).last?["replay_history_rows"] as? Int == DaemonTerminalSession.historyChunkRows)
        #expect(text(events) == "\u{1B}c[2000 rows]hello\r\n$ ")
        #expect(!events.contains { if case .connection(let state) = $0 { !state.isAttached } else { false } })
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "release-surface-size" } }

        // The last 1,500 rows fit one chunk: the next fetch asks for all of them.
        session.loadOlderHistory()
        try await waitUntil { session.historyRowsOmitted == 0 }
        #expect(attaches(daemon).count == 3)
        #expect(attaches(daemon).last?["replay_history_rows"] == nil)
        session.loadOlderHistory()
        try await Task.sleep(for: .milliseconds(100))
        #expect(attaches(daemon).count == 3, "the mirror has the whole history now")
        #expect(session.isAttached)
    }

    /// A `resized` replay brings the whole history: nothing is left to fetch.
    @Test func aResizedReplayHoldsTheWholeHistory() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.historyRows = 9_000
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        session.start { _ in }
        // The attach is marked before its replay's `vt-state` names the rows
        // omitted: wait for both.
        try await waitUntil { session.isAttached && session.historyRowsOmitted == 9_000 }
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 60, "rows": 20,
                                                "replay": Data("all".utf8).base64EncodedString()]))
        #expect(session.historyRowsOmitted == 0)
    }

    /// A reattach after a dropped link keeps the rows the reader fetched,
    /// so their place is still in the replay.
    @Test func aReattachKeepsTheFetchedAllowance() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.historyRows = 9_000
        let channels = ChannelLog()
        let session = session(daemon, channels)
        defer { session.stop() }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        session.loadOlderHistory()
        try await waitUntil { session.historyRowsOmitted == 7_000 }
        await channels.last?.close(code: "eof", reason: "remote closed")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        try await waitUntil { session.isAttached && attaches(daemon).count == 3 }
        #expect(attaches(daemon).last?["replay_history_rows"] as? Int == DaemonTerminalSession.historyChunkRows)
    }

    /// A tab back from the warm set (a new host, Leo 2026-11-14) puts its
    /// reader back 2,500 rows above the end: its first attach asks for those
    /// rows at once, in whole chunks, not the screen alone and then a refetch.
    @Test func aTabBackFromTheWarmSetAsksForItsReadersRowsInTheFirstAttach() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.historyRows = 9_000
        daemon.afterAttach = nil
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        session.requestHistoryRows(2_500)
        session.start { _ in }
        try await waitUntil { session.isAttached && session.historyRowsOmitted == 5_000 }
        #expect(attaches(daemon).count == 1)
        #expect(attaches(daemon).first?["replay_history_rows"] as? Int == 2 * DaemonTerminalSession.historyChunkRows)
        #expect(session.historyRowsOmitted == 5_000)
    }

    // MARK: The Mac keeps the scrollback (attach-replay-history-window-v1)

    /// Leo, 2026-11-14: "is there a way to do it and like maintain expected
    /// behavior while not needing to f***ing stream the literal f***ing Mac
    /// screen on the f***ing phone?" A reader who scrolls a 100,000-row
    /// history all the way back reaches line 1, and no replay on the way
    /// holds more than 10,000 rows: the phone holds a window of the Mac's
    /// history, never all of it. Before, each fetch asked for 2,000 more
    /// rows, and the last ones asked for the whole history.
    @Test func scrollingAHundredThousandRowHistoryToLineOneHoldsABoundedWindow() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.windowReplay = true
        daemon.historyRows = 100_000
        daemon.afterAttach = nil
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        #expect(attaches(daemon).first?["replay_history_rows"] as? Int == 0, "the attach is the screen alone")
        events.removeAll()

        var fetches = 0
        while session.historyRowsOmitted > 0, fetches < 200 {
            // Each fetch waits for the one before it (one at a time).
            try await ask { session.historyRowsOmitted == 0 || session.loadOlderHistory() }
            fetches += 1
        }
        try await waitUntil { session.historyRowsOmitted == 0 }
        #expect(session.historyRowsOmitted == 0, "line 1 is reached")
        let held = daemon.replayedHistoryRows
        #expect(held.max() ?? 0 <= 10_000, "a replay held \(held.max() ?? 0) of the Mac's 100,000 history rows")
        #expect(attaches(daemon).allSatisfy { $0["replay_history_rows"] != nil }, "no fetch asked for the whole history")
        #expect(fetches <= 80, "\(fetches) fetches to line 1")
        #expect(attaches(daemon).last?["replay_history_start"] as? Int == 0)
        #expect(text(events).hasSuffix("\u{1B}c[rows 0..<4000]hello\r\n$ "), "the mirror starts at line 1")
        #expect(!events.contains { if case .connection(let state) = $0 { !state.isAttached } else { false } })
    }

    /// The phone tells the Mac it reads the rows a `resized` replay leaves out.
    @Test func theAttachDeclaresTheHistoryWindow() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.windowReplay = true
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let info = daemon.recorded.first { $0["cmd"] as? String == "set-client-info" }
        #expect((info?["capabilities"] as? [String])?.contains("attach-replay-history-window-v1") == true)
    }

    /// A `resized` replay of the Mac's history window (a resize, the phone's
    /// keyboard, the Mac's own window) keeps only the newest rows: the rows it
    /// names as left out are still the Mac's to send, not lost.
    @Test func aWindowedResizedReplayKeepsTheOlderRowsFetchable() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.windowReplay = true
        daemon.historyRows = 100_000
        daemon.afterAttach = nil
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 60, "rows": 20,
                                                "replay": Data("screen".utf8).base64EncodedString(),
                                                "history_rows_omitted": 101_000]))
        #expect(session.historyRowsOmitted == 101_000)
        #expect(session.loadOlderHistory(), "older rows are fetched after the resize")
    }

    /// A Mac app older than its daemon refuses the window field while the
    /// daemon still advertises it: after the first refusal the session fetches
    /// the newest rows in chunks, as before the window, and line 1 is reached.
    /// Before, every replacement attach asked for a window again, and the
    /// reader never got past about 12,000 rows.
    @Test func aLaneThatRefusesTheWindowStillReachesLineOne() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.windowReplay = true
        daemon.laneRefusesHistoryStart = true
        daemon.historyRows = 30_000
        daemon.afterAttach = nil
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        var fetches = 0
        while session.historyRowsOmitted > 0, fetches < 60 {
            try await ask { session.historyRowsOmitted == 0 || session.loadOlderHistory() }
            fetches += 1
        }
        try await waitUntil { session.historyRowsOmitted == 0 }
        #expect(session.historyRowsOmitted == 0, "line 1 is reached after \(fetches) fetches")
        #expect(attaches(daemon).filter { $0["replay_history_start"] != nil }.count == 1, "one refused window, then chunks")
    }

    /// Past the newest 10,000 rows the mirror holds a window: coming back down
    /// moves it toward the screen until the Mac sends the rows down to the
    /// screen again; coming up from the screen brings the newest rows at once.
    @Test func comingBackDownFromAWindowReachesTheNewestRows() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.tailReplay = true
        daemon.windowReplay = true
        daemon.historyRows = 100_000
        daemon.afterAttach = nil
        let session = session(daemon, ChannelLog())
        defer { session.stop() }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        var fetches = 0
        while session.historyWindowRows == nil, fetches < 20 {
            try await ask { session.historyWindowRows != nil || session.loadOlderHistory() }
            fetches += 1
        }
        try await waitUntil { session.historyWindowRows != nil }
        #expect(session.historyWindowRows == DaemonTerminalSession.historyWindowRows)
        let start = try #require(attaches(daemon).last?["replay_history_start"] as? Int)

        // Down a step: the window moves toward the screen.
        try await ask { session.loadNewerHistory(toTheScreen: false) }
        try await waitUntil { session.historyRowsOmitted == start + DaemonTerminalSession.historyWindowStep }
        #expect(session.historyWindowRows != nil)

        // Up from the screen to the window: the newest rows, contiguous again.
        try await ask { session.loadNewerHistory(toTheScreen: true) }
        // The tail has landed once no rows are skipped (the window step above
        // also left 90,000 rows above the mirror).
        try await waitUntil { session.historyRowsSkipped == 0 && session.historyRowsOmitted == 90_000 }
        #expect(session.historyWindowRows == nil)
        #expect(attaches(daemon).last?["replay_history_rows"] as? Int == DaemonTerminalSession.maxTailHistoryRows)
        #expect(attaches(daemon).last?["replay_history_start"] == nil)
        #expect(session.historyRowsSkipped == 0)
    }

    /// Calls `request` until it answers true (a fetch started, or none is
    /// needed), and never again after: unlike ``waitUntil(attempts:_:)``,
    /// whose last check would start a second fetch.
    private func ask(attempts: Int = 300, _ request: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts {
            if request() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the request never started")
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
