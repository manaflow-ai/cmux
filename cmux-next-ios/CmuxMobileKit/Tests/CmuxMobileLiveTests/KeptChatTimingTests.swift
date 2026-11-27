import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

/// conn-quiet timing (Leo, 2026-11-14: "load faster/percievably load faster"): a relaunch reopens
/// a chat whose turns only the disk holds (120 turns, 600 records: the kept copy's record limit),
/// with no link. Timed from the chat's source being made to its store holding the newest turn.
/// The same harness runs at the base and the head; it prints one `CONNQUIET {json}` line with p50
/// and p95 in ms and how many runs had the kept turns restored in the source's init (the same turn
/// as the open). It asserts nothing about time: it is the measurement, not a gate.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct KeptChatTimingTests {
    typealias Long = LongChatOpenLiveTests

    @Test func keptChatToItsNewestTurnAfterARelaunch() async throws {
        let directory = AgentKeptTranscriptTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        let writer = AgentKeptTranscriptTests.cache(directory)
        writer.save(key, sessionID: "s1", earlier: true, records: AgentKeptTranscriptTests.json((0..<120).flatMap(Long.turnRecords)))
        writer.flush()

        var samples: [Double] = []
        var sameTurn = 0
        let runs = 31
        for _ in 0..<runs {
            // A new run: nothing in memory.
            let cache = AgentKeptTranscriptTests.cache(directory)
            let start = ContinuousClock.now
            let source = AgentKeptTranscriptTests.hub(cache).source(sessionID: "s1", summary: AgentKeptTranscriptTests.summary)
            if source.replayCount > 0 { sameTurn += 1 }
            let store = AgentChatStore(source: source)
            // Bounded and named: a bare `while ... { await Task.yield() }` never checks cancellation, so the
            // suite's time limit could not stop it and the simulator step ran to its 30 min timeout silent.
            var deadline = AwakeDeadline(.seconds(30))
            while store.turns.last?.id != "t119", !Task.isCancelled, deadline.hasTimeLeft() { await Task.yield() }
            guard store.turns.last?.id == "t119" else {
                Issue.record("kept chat never reached its newest turn t119 (last: \(store.turns.last?.id ?? "none"), turns: \(store.turns.count))")
                return
            }
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[min(samples.count - 1, Int((Double(samples.count) * 0.95).rounded(.up)) - 1)]
        let line = #"CONNQUIET {"metric":"kept_chat_newest_turn_after_relaunch","records":600,"runs":\#(runs),"p50_ms":\#(p50),"p95_ms":\#(p95),"same_turn":\#(sameTurn)}"#
        print(line)
        // The step artifact keeps attachments, not print lines (its console log comes back empty).
        Attachment.record(line, named: "connquiet-chat.txt")
    }
}
