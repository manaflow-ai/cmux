import CmuxAgentReplica
import Foundation
@testable import CmuxAgentTruthKit
import Testing

@Suite
struct TranscriptDecoderTests {
    @Test
    func claudeGoldenFixture() throws {
        let lines = try fixtureLines("claude-synthetic")
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "claude-journal"))

        #expect(kindTable(batch.entries) == [
            "0:fixture_comment",
            "1:userMessage",
            "2:agentProse",
            "3:thought",
            "4:toolRun",
            "5:toolRun",
            "6:fileChange",
            "7:question",
            "10:toolRun",
            "11:future_block",
            "12:malformed",
            "13:future_record",
        ])
        #expect(batch.diagnostics.unknownKindCounts["malformed"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["future_block"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["sidechain"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["meta"] == 1)
    }

    @Test
    func codexGoldenFixture() throws {
        let lines = try fixtureLines("codex-synthetic")
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "codex-journal"))

        #expect(kindTable(batch.entries) == [
            "0:fixture_comment",
            "1:status",
            "2:userMessage",
            "3:agentProse",
            "4:thought",
            "5:toolRun",
            "6:toolRun",
            "7:fileChange",
            "8:toolRun",
            "10:status",
            "11:status",
            "12:malformed",
            "13:future_item",
        ])
        #expect(batch.diagnostics.unknownKindCounts["malformed"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["future_item"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["event_msg.task_started"] == 1)
        #expect(batch.diagnostics.cliVersion == "0.140.0")
        #expect(batch.payloads[EntryCoordinate(journalID: JournalID(rawValue: "codex-journal"), seq: EntrySeq(rawValue: 5))]?.summary.contains("echo example") == true)
    }

    @Test
    func claudeIncrementalBoundariesMatchOneShot() throws {
        let lines = try fixtureLines("claude-synthetic")
        var oneShot = ClaudeTranscriptDecoder()
        let expected = oneShot.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))
        for split in 0 ... lines.count {
            var decoder = ClaudeTranscriptDecoder()
            let first = decoder.feed(Array(lines.prefix(split)), startingAt: 0, journalID: JournalID(rawValue: "journal"))
            let second = decoder.feed(Array(lines.dropFirst(split)), startingAt: split, journalID: JournalID(rawValue: "journal"))
            #expect(first.entries + second.entries == expected.entries)
        }
    }

    @Test
    func codexIncrementalBoundariesMatchOneShot() throws {
        let lines = try fixtureLines("codex-synthetic")
        var oneShot = CodexTranscriptDecoder()
        let expected = oneShot.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))
        for split in 0 ... lines.count {
            var decoder = CodexTranscriptDecoder()
            let first = decoder.feed(Array(lines.prefix(split)), startingAt: 0, journalID: JournalID(rawValue: "journal"))
            let second = decoder.feed(Array(lines.dropFirst(split)), startingAt: split, journalID: JournalID(rawValue: "journal"))
            #expect(first.entries + second.entries == expected.entries)
        }
    }

    private func fixtureLines(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func kindTable(_ entries: [EntrySnapshot]) -> [String] {
        entries.map { "\($0.seq.rawValue):\($0.kind.rawValue)" }
    }
}
