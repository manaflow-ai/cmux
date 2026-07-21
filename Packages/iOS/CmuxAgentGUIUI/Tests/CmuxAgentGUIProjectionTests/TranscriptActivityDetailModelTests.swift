@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Testing

@Suite("Transcript activity detail model")
struct TranscriptActivityDetailModelTests {
    @Test("tool details retain command input output status and duration")
    func toolDetails() {
        let model = Self.model(payload: .toolRun(ToolRunPayload(
            toolName: "bash",
            argumentSummary: "swift test",
            resultSummary: "Passed",
            isTerminal: true,
            exitCode: 0,
            isRunning: false,
            inputDetail: "{\"cwd\":\"/repo\"}",
            command: "swift test",
            output: "107 tests passed",
            durationSeconds: 3.25,
            status: "completed"
        )))

        #expect(model.sections.contains { $0.label == .tool && $0.value == "bash" })
        #expect(model.sections.contains { $0.label == .arguments && $0.isCode })
        #expect(model.sections.contains { $0.label == .command && $0.value == "swift test" })
        #expect(model.sections.contains { $0.label == .output && $0.value == "107 tests passed" })
        #expect(model.sections.contains { $0.label == .status && $0.value == "completed" })
        #expect(model.sections.contains { $0.label == .duration })
    }

    @Test("file details retain path counts result and unified diff")
    func fileDetails() {
        let model = Self.model(payload: .fileChange(FileChangePayload(
            path: "Sources/App.swift",
            changeKind: .edit,
            resultSummary: "Updated renderer",
            additions: 8,
            deletions: 2,
            unifiedDiff: "@@ -1 +1 @@\n-old\n+new"
        )))

        #expect(model.sections.contains { $0.label == .path && $0.value == "Sources/App.swift" })
        #expect(model.sections.contains { $0.label == .changes && $0.value.contains("+8") })
        #expect(model.sections.contains { $0.label == .result && $0.value == "Updated renderer" })
        #expect(model.sections.contains { $0.label == .diff && $0.isCode })
    }

    @Test("unknown raw JSON appears only as a fallback without a summary")
    func unknownFallback() {
        let summarized = Self.model(payload: .unknown(UnknownPayload(
            rawKind: "future",
            summary: "Useful summary",
            rawJSON: "{\"secret\":true}"
        )))
        #expect(!summarized.sections.contains { $0.label == .diagnostic })

        let fallback = Self.model(payload: .unknown(UnknownPayload(
            rawKind: "future",
            rawJSON: "{\"value\":1}"
        )))
        #expect(fallback.sections.contains { $0.label == .diagnostic && $0.isCode })
    }

    @Test("attachment details format metadata instead of exposing a raw byte integer")
    func attachmentMetadata() {
        let model = Self.model(payload: .attachment(AttachmentPayload(
            kind: "image",
            summary: "Screenshot",
            displayName: "screen.png",
            hostPath: "/tmp/screen.png",
            mimeType: "image/png",
            byteCount: 1_024,
            width: 800,
            height: 600
        )))

        let metadata = model.sections.first { $0.label == .metadata }?.value
        #expect(metadata?.contains("image/png") == true)
        #expect(metadata?.contains("800 × 600") == true)
        #expect(metadata != "1024")
    }

    private static func model(payload: EntryPayload) -> TranscriptActivityDetailModel {
        let journal = JournalID(rawValue: "detail")
        let entry = EntrySnapshot(
            journalID: journal,
            seq: EntrySeq(rawValue: 1),
            kind: payload.kind,
            content: EntryContent(contentHash: 1, payload: payload),
            version: EntityVersion(rawValue: 1)
        )
        let item = TranscriptActivityItem(
            id: .entry(journalID: journal, seq: entry.seq),
            kind: .tool,
            summary: "summary",
            isRunning: false,
            sourceEntry: entry
        )
        return TranscriptActivityDetailModel(item: item)
    }
}
