import Foundation
import CmuxAgentTruthKit
@testable import CmuxAgentTranscriptHarvest
import Testing

@Suite
struct TranscriptShapeInventoryTests {
    @Test
    func extractsClaudeShapeFactsWithoutContent() {
        let plantedUserText = "SECRET_MARKER_SHOULD_NOT_LEAK"
        let line = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"\(plantedUserText)"},{"type":"tool_use","name":"Bash","input":{"command":"\(plantedUserText)"}},{"type":"future_block","text":"\(plantedUserText)"}]},"isSidechain":true,"futureKey":"\(plantedUserText)"}
        """
        var inventory = TranscriptShapeInventory()
        inventory.feed(source: .claude, rawLine: line)

        let rendered = renderedRows(inventory.rows())
        #expect(rendered.contains("claude|record_type|assistant|1"))
        #expect(rendered.contains("claude|block_type|text|1"))
        #expect(rendered.contains("claude|block_type|tool_use|1"))
        #expect(rendered.contains("claude|block_type|future_block|1"))
        #expect(rendered.contains("claude|tool_name|Bash|1"))
        #expect(rendered.contains("claude|flag|isSidechain|1"))
        #expect(rendered.contains("claude|unfamiliar_top_level_key|futureKey|1"))
        #expect(!rendered.contains(plantedUserText))
    }

    @Test
    func extractsCodexShapeFactsAndSanitizesNonIdentifiers() {
        let plantedUserText = "SECRET_MARKER_SHOULD_NOT_LEAK"
        let lines = [
            #"{"type":"session_meta","payload":{"cli_version":"0.140.0","cwd":"/private/secret"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"SECRET_MARKER_SHOULD_NOT_LEAK\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"bad/name","input":"SECRET_MARKER_SHOULD_NOT_LEAK"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","note":"SECRET_MARKER_SHOULD_NOT_LEAK"}}"#,
        ]
        var inventory = TranscriptShapeInventory()
        for line in lines {
            inventory.feed(source: .codex, rawLine: line)
        }

        let rendered = renderedRows(inventory.rows())
        #expect(rendered.contains("codex|record_type|session_meta|1"))
        #expect(rendered.contains("codex|record_type|response_item|2"))
        #expect(rendered.contains("codex|payload_type|function_call|1"))
        #expect(rendered.contains("codex|payload_type|custom_tool_call|1"))
        #expect(rendered.contains("codex|function_call_name|shell|1"))
        #expect(rendered.contains("codex|function_call_name|non_identifier|1"))
        #expect(rendered.contains("codex|event_msg_type|task_started|1"))
        #expect(rendered.contains("codex|cli_version|0.140.0|1"))
        #expect(!rendered.contains(plantedUserText))
        #expect(!rendered.contains("/private/secret"))
    }

    @Test
    func claudeDecoderGapMarkersUseRecoveredOriginDimension() {
        var recordGap = TranscriptDecoderGapInventory()
        recordGap.record(
            source: .claude,
            rawLine: #"{"type":"future_kind","message":{"content":[{"type":"text","text":"ignored"}]}}"#,
            diagnostics: TranscriptDecoderDiagnostics(unknownKindCounts: ["future_kind": 1])
        )
        #expect(recordGap.contains(source: .claude, dimension: "record_type", value: "future_kind"))
        #expect(!recordGap.contains(source: .claude, dimension: "block_type", value: "future_kind"))

        var blockGap = TranscriptDecoderGapInventory()
        blockGap.record(
            source: .claude,
            rawLine: #"{"type":"assistant","message":{"content":[{"type":"future_kind","text":"ignored"}]}}"#,
            diagnostics: TranscriptDecoderDiagnostics(unknownKindCounts: ["future_kind": 1])
        )
        #expect(!blockGap.contains(source: .claude, dimension: "record_type", value: "future_kind"))
        #expect(blockGap.contains(source: .claude, dimension: "block_type", value: "future_kind"))
    }

    @Test
    func codexDecoderGapMarkersUseRecoveredOriginDimension() {
        var recordGap = TranscriptDecoderGapInventory()
        recordGap.record(
            source: .codex,
            rawLine: #"{"type":"turn_context","payload":{"cwd":"/tmp/example"}}"#,
            diagnostics: TranscriptDecoderDiagnostics(unknownKindCounts: ["turn_context": 1])
        )
        #expect(recordGap.contains(source: .codex, dimension: "record_type", value: "turn_context"))
        #expect(!recordGap.contains(source: .codex, dimension: "payload_type", value: "turn_context"))

        var payloadGap = TranscriptDecoderGapInventory()
        payloadGap.record(
            source: .codex,
            rawLine: #"{"type":"response_item","payload":{"type":"tool_search_call","query":"ignored"}}"#,
            diagnostics: TranscriptDecoderDiagnostics(unknownKindCounts: ["tool_search_call": 1])
        )
        #expect(!payloadGap.contains(source: .codex, dimension: "record_type", value: "tool_search_call"))
        #expect(payloadGap.contains(source: .codex, dimension: "payload_type", value: "tool_search_call"))
    }

    private func renderedRows(_ rows: [TranscriptShapeRow]) -> String {
        rows.map { "\($0.source.rawValue)|\($0.dimension)|\($0.value)|\($0.count)" }.joined(separator: "\n")
    }
}
