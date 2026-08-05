import Foundation
@testable import CmuxAgentTranscriptHarvest
import Testing

@Suite
struct TranscriptHarvestScannerTests {
    @Test
    func walksJsonlFixturesAndStreamsIntoInventory() throws {
        let root = try TemporaryHarvestFixture()
        try root.writeClaudeFile(
            named: "claude.jsonl",
            lines: [
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
                #"{"type":"user","message":{"content":[{"type":"text","text":"SECRET_MARKER_SHOULD_NOT_LEAK"}]}}"#,
            ]
        )
        try root.writeCodexFile(
            named: "codex.jsonl",
            lines: [
                #"{"type":"session_meta","payload":{"cli_version":"0.140.0"}}"#,
                #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            ]
        )

        let result = TranscriptHarvestScanner(fileManager: .default).scan(
            claudeRoot: root.claudeRoot,
            codexRoot: root.codexRoot,
            maxFiles: nil,
            modifiedSince: nil
        )

        let rendered = TranscriptHarvestFormatter().tsv(result)
        #expect(rendered.contains("claude\trecord_type\tassistant\t1"))
        #expect(rendered.contains("claude\ttool_name\tBash\t1"))
        #expect(rendered.contains("codex\tcli_version\t0.140.0\t1"))
        #expect(rendered.contains("codex\tevent_msg_type\ttask_started\t1\t"))
        #expect(rendered.contains("claude\tsummary\tfiles_scanned\t1"))
        #expect(rendered.contains("codex\tsummary\tlines_scanned\t2"))
        #expect(!rendered.contains("SECRET_MARKER_SHOULD_NOT_LEAK"))
        // Nothing in this fixture is unknown to the decoders, so no row may
        // carry the gap marker; modeled skips regressing to DECODER-GAP fails here.
        #expect(!rendered.contains("DECODER-GAP"))
    }

    @Test
    func maxFilesLimitsEachSource() throws {
        let root = try TemporaryHarvestFixture()
        try root.writeClaudeFile(named: "a.jsonl", lines: [#"{"type":"assistant"}"#])
        try root.writeClaudeFile(named: "b.jsonl", lines: [#"{"type":"assistant"}"#])
        try root.writeCodexFile(named: "c.jsonl", lines: [#"{"type":"session_meta","payload":{"cli_version":"0.140.0"}}"#])

        let result = TranscriptHarvestScanner(fileManager: .default).scan(
            claudeRoot: root.claudeRoot,
            codexRoot: root.codexRoot,
            maxFiles: 2,
            modifiedSince: nil
        )

        #expect(result.summaries[.claude]?.filesScanned == 2)
        #expect(result.summaries[.codex]?.filesScanned == 1)
    }
}
