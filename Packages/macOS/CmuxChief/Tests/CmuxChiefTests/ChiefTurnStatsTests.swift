@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

@Suite struct ChiefTurnStatsTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    private func owner(_ brain: FakeBrain, engine: ChiefTurnEngine?,
                       now: @escaping @Sendable () -> Date = { Date() }) throws -> ChiefConversationOwner {
        let home = ChiefFixture().home
        return try ChiefConversationOwner(home: home, brain: brain, userDisplayName: "Tester", now: now) { _ in
            ChiefTurnContext(systemPrompt: "You are Chief.", workingDirectory: home.root, engine: engine)
        }
    }

    /// The settings panel's "Last turn" line: engine, tool calls and cache share of the last finished turn.
    @Test func finishedTurnRecordsEngineToolsAndCache() async throws {
        let brain = FakeBrain.events([
            .toolStarted(id: "t1", title: "cmux tree", detail: nil),
            .toolFinished(id: "t1", ok: true, preview: nil),
            .toolStarted(id: "t2", title: "cmux send", detail: nil),
            .toolFinished(id: "t2", ok: false, preview: nil),
            .textDelta("done"),
            .textSegmentEnd,
            .usage(ChiefTurnUsage(inputTokens: 20, cacheReadTokens: 60, cacheWriteTokens: 20)),
            .finished,
        ])
        let engine = ChiefTurnEngine(harness: "claude", model: "claude-opus-5-5", effort: "medium")
        // A fixed clock: the turn starts and ends at the same instant.
        let owner = try owner(brain, engine: engine, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        #expect(await owner.lastTurnStats(in: conversation) == nil)
        try await ChiefFixture.send("hi", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 4)
        let stats = try #require(await owner.lastTurnStats(in: conversation))
        #expect(stats.engine == engine)
        #expect(stats.toolCalls == 2)
        #expect(stats.failedToolCalls == 1)
        #expect(stats.cacheHitRate == 0.6)
        #expect(!stats.failed)
        #expect(!stats.stopped)
        #expect(stats.duration == 0)
    }

    @Test func claudeResultUsageBecomesAUsageEvent() throws {
        let line = try ChiefJSON(parsing: Data(#"{"input_tokens":10,"cache_read_input_tokens":30}"#.utf8))
        #expect(ClaudeStreamParser.usage(line) == ChiefTurnUsage(inputTokens: 10, cacheReadTokens: 30))
        #expect(ClaudeStreamParser.usage(nil) == nil)
        #expect(ChiefTurnUsage(inputTokens: 0, cacheReadTokens: 0).cacheHitRate == nil)
    }

    @Test func successfulResultReportsUsageBeforeFinished() {
        var lines = ChiefBrainFixtures.claudeTextTurn
        lines[lines.count - 1] = lines[lines.count - 1].replacingOccurrences(
            of: #""type":"result","#,
            with: #""type":"result","usage":{"input_tokens":5,"cache_read_input_tokens":15},"#)
        var parser = ClaudeStreamParser()
        parser.beginTurn(echo: ChiefBrainFixtures.claudePromptUUID)
        let outputs = lines.flatMap { parser.consume(Data($0.utf8)) }
        #expect(outputs.suffix(2) == [.event(.usage(ChiefTurnUsage(inputTokens: 5, cacheReadTokens: 15))), .event(.finished)])
    }

    @Test func renameChiefsUpdatesEveryChiefParticipant() async throws {
        let owner = try ChiefFixture().owner(.replying(["hi"]))
        let changed = try await owner.renameChiefs(to: "  Jarvis ")
        #expect(changed == [conversation])
        let inbox = await owner.inbox()
        let summary = try #require(inbox.conversations.first { $0.id == conversation })
        #expect(summary.participants.contains { $0.isChief && $0.displayName == "Jarvis" })
        #expect(try await owner.renameChiefs(to: "Jarvis").isEmpty)
        await #expect(throws: HomeRejection.self) { try await owner.renameChiefs(to: "   ") }
    }

    @Test func logFileIsTheConversationsJSONL() throws {
        let owner = try ChiefFixture().owner(.replying(["hi"]))
        let url = owner.logFile(for: conversation)
        #expect(url.pathExtension == "jsonl")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
