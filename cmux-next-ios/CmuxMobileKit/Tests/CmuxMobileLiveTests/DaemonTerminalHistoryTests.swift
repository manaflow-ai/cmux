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
        try await waitUntil { session.isAttached }
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
        try await waitUntil { session.isAttached }
        #expect(session.historyRowsOmitted == 9_000)
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

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
