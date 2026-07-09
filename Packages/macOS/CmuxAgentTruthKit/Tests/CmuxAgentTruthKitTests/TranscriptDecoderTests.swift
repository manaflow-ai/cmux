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
            "11:status",
            "12:status",
            "14:userMessage",
            "26:future_block",
            "27:malformed",
            "28:future_record",
        ])
        #expect(batch.diagnostics.unknownKindCounts["malformed"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["future_block"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["sidechain"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["meta"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["system.api_error"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["system.stop_hook_summary"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["system.turn_duration"] == 1)
        #expect(batch.diagnostics.bookkeepingKindCounts["ai-title"] == 1)
        #expect(batch.diagnostics.bookkeepingKindCounts["attachment"] == 1)
        #expect(batch.diagnostics.sawApiError)
        #expect(batch.diagnostics.sensitiveSessionTitles.map(\.source) == ["ai-title", "custom-title", "agent-name"])
        #expect(userMessagePayload(in: batch, seq: 14)?.hasImage == true)
        #expect(userMessagePayload(in: batch, seq: 14)?.attachmentCount == 1)
        #expect(toolRunPayload(in: batch, seq: 5)?.exitCode == 0)
        #expect(fileChangePayload(in: batch, seq: 6)?.path == "/tmp/example/file.txt")
        #expect(questionPayload(in: batch, seq: 7)?.options == ["Alpha", "Beta"])
        #expect(statusPayload(in: batch, seq: 11)?.code == .apiError)
        #expect(unknownPayload(in: batch, seq: 26)?.rawKind == "future_block")
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
            "8:fileChange",
            "9:toolRun",
            "10:toolRun",
            "11:toolRun",
            "15:status",
            "16:status",
            "27:malformed",
            "28:future_item",
        ])
        #expect(batch.diagnostics.unknownKindCounts["malformed"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["future_item"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["event_msg.task_started"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["event_msg.task_complete"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["event_msg.context_compacted"] == 1)
        #expect(batch.diagnostics.duplicateStreamCounts["event_msg.user_message"] == 1)
        #expect(batch.diagnostics.duplicateStreamCounts["event_msg.agent_message"] == 1)
        #expect(batch.diagnostics.phaseFacts == [.taskStarted(line: 13), .taskCompleted(line: 14), .turnAborted(line: 15)])
        #expect(batch.diagnostics.turnContextFacts == [TurnContextFact(line: 12, model: "gpt-5.5", sandboxPolicy: "danger-full-access", approvalPolicy: "never")])
        #expect(batch.diagnostics.cliVersion == "0.140.0")
        #expect(toolRunPayload(in: batch, seq: 5)?.argumentSummary.contains("echo example") == true)
        #expect(fileChangePayload(in: batch, seq: 8)?.resultSummary?.contains("patch applied") == true)
        #expect(statusPayload(in: batch, seq: 15)?.code == .turnAborted)
    }

    @Test
    func codexCustomToolOutputPairsByCallID() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_patch","input":"patch placeholder"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_patch","output":"patch complete"}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:fileChange", "1:fileChange"])
        #expect(fileChangePayload(in: batch, seq: 1)?.resultSummary?.contains("patch complete") == true)
        #expect(batch.diagnostics.unknownKindCounts.isEmpty)
    }

    @Test
    func codexToolSearchOutputPairsByCallID() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"tool_search_call","call_id":"call_search","arguments":{"query":"example"}}}"#,
            #"{"type":"response_item","payload":{"type":"tool_search_output","call_id":"call_search","status":"completed","tools":[{"name":"example_tool"}]}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:toolRun", "1:toolRun"])
        #expect(toolRunPayload(in: batch, seq: 1)?.toolName == "tool_search")
        #expect(batch.diagnostics.unknownKindCounts.isEmpty)
    }

    @Test
    func codexUnpairedOutputUnknownKeysKeepPayloadType() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"missing_patch","output":"patch complete"}}"#,
            #"{"type":"response_item","payload":{"type":"tool_search_output","call_id":"missing_search","status":"completed","tools":[]}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:custom_tool_call_output", "1:tool_search_output"])
        #expect(batch.diagnostics.unknownKindCounts["custom_tool_call_output"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["tool_search_output"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["function_call_output"] == nil)
    }

    @Test
    func codexPhaseFactsAndEventCompactionStatus() {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_example"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_example"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn_example"}}"#,
            #"{"type":"event_msg","payload":{"type":"context_compacted"}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 40, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["42:status", "43:status"])
        #expect(batch.diagnostics.phaseFacts == [.taskStarted(line: 40), .taskCompleted(line: 41), .turnAborted(line: 42)])
    }

    @Test
    func codexOutOfRangeExitCodeFailsOpen() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"call_huge","arguments":{"command":["bash","-lc","echo done"]}}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_huge","output":"done","exit_code":1e300}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(toolRunPayload(in: batch, seq: 1)?.exitCode == nil)
        #expect(toolRunPayload(in: batch, seq: 1)?.isRunning == false)
    }

    @Test
    func codexTerminalClassificationUsesNameAndParsedCommandArray() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"function_call","name":"search_docs","arguments":"{\"query\":\"bash reference\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"custom_runner","arguments":"{\"command\":[\"bash\",\"-lc\",\"echo done\"]}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"query\":\"reference\"}"}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(toolRunPayload(in: batch, seq: 0)?.isTerminal == false)
        #expect(toolRunPayload(in: batch, seq: 1)?.isTerminal == true)
        #expect(toolRunPayload(in: batch, seq: 2)?.isTerminal == true)
    }

    @Test
    func claudeNonShellToolResultSynthesizesZeroExitCode() {
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool_non_shell","name":"WebSearch","input":{"query":"example"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_non_shell","content":"result","is_error":false}]}}"#,
        ]
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(toolRunPayload(in: batch, seq: 1)?.isTerminal == false)
        #expect(toolRunPayload(in: batch, seq: 1)?.exitCode == 0)
    }

    @Test
    func claudeImageBlockChangesUserMessageContentHash() throws {
        let plain = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Same prompt."}]}}"#,
        ]
        let withImage = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Same prompt."},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"<redacted-image-data>"}}]}}"#,
        ]
        var plainDecoder = ClaudeTranscriptDecoder()
        var imageDecoder = ClaudeTranscriptDecoder()
        let plainEntry = try #require(plainDecoder.feed(plain, startingAt: 0, journalID: JournalID(rawValue: "journal")).entries.first)
        let imageBatch = imageDecoder.feed(withImage, startingAt: 0, journalID: JournalID(rawValue: "journal"))
        let imageEntry = try #require(imageBatch.entries.first)

        #expect(plainEntry.kind == .userMessage)
        #expect(imageEntry.kind == .userMessage)
        #expect(plainEntry.content != imageEntry.content)
        #expect(userMessagePayload(in: imageBatch, seq: 0)?.hasImage == true)
        #expect(userMessagePayload(in: imageBatch, seq: 0)?.attachmentCount == 1)
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
            #expect(mergedDiagnostics(first.diagnostics, second.diagnostics) == expected.diagnostics)
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
            #expect(mergedDiagnostics(first.diagnostics, second.diagnostics) == expected.diagnostics)
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

    private func payload(in batch: TranscriptDecodeBatch, seq: Int) -> EntryPayload? {
        batch.entries.first { $0.seq == EntrySeq(rawValue: seq) }?.content.payload
    }

    private func userMessagePayload(in batch: TranscriptDecodeBatch, seq: Int) -> UserMessagePayload? {
        if case .userMessage(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func toolRunPayload(in batch: TranscriptDecodeBatch, seq: Int) -> ToolRunPayload? {
        if case .toolRun(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func fileChangePayload(in batch: TranscriptDecodeBatch, seq: Int) -> FileChangePayload? {
        if case .fileChange(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func questionPayload(in batch: TranscriptDecodeBatch, seq: Int) -> QuestionPayload? {
        if case .question(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func statusPayload(in batch: TranscriptDecodeBatch, seq: Int) -> StatusPayload? {
        if case .status(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func unknownPayload(in batch: TranscriptDecodeBatch, seq: Int) -> UnknownPayload? {
        if case .unknown(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func mergedDiagnostics(
        _ first: TranscriptDecoderDiagnostics,
        _ second: TranscriptDecoderDiagnostics
    ) -> TranscriptDecoderDiagnostics {
        TranscriptDecoderDiagnostics(
            unknownKindCounts: mergedCounts(first.unknownKindCounts, second.unknownKindCounts),
            modeledKindCounts: mergedCounts(first.modeledKindCounts, second.modeledKindCounts),
            duplicateStreamCounts: mergedCounts(first.duplicateStreamCounts, second.duplicateStreamCounts),
            bookkeepingKindCounts: mergedCounts(first.bookkeepingKindCounts, second.bookkeepingKindCounts),
            cliVersion: second.cliVersion ?? first.cliVersion,
            phaseFacts: first.phaseFacts + second.phaseFacts,
            turnContextFacts: first.turnContextFacts + second.turnContextFacts,
            sawApiError: first.sawApiError || second.sawApiError,
            sensitiveSessionTitles: first.sensitiveSessionTitles + second.sensitiveSessionTitles
        )
    }

    private func mergedCounts(_ first: [String: Int], _ second: [String: Int]) -> [String: Int] {
        first.merging(second) { lhs, rhs in lhs + rhs }
    }
}
