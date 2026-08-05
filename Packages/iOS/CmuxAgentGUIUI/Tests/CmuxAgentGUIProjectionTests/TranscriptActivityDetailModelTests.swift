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

    @Test("sparse activity details fail open instead of trapping")
    func sparseActivityDetailsFailOpen() {
        let model = Self.model(
            payload: .unknown(UnknownPayload(rawKind: "")),
            itemKind: .unknown(""),
            itemSummary: ""
        )

        #expect(model.title == "Activity")
        #expect(model.sections.count == 1)
        #expect(model.sections.first?.label == .summary)
        #expect(model.sections.first?.value == "Activity")
        #expect(model.sections.first?.isCode == false)
    }

    @Test("large activity details are bounded before sheet presentation")
    func largeActivityDetailsAreBounded() {
        let output = String(repeating: "0123456789", count: 7_000)
        let model = Self.model(payload: .toolRun(ToolRunPayload(
            toolName: "bash",
            argumentSummary: "large output",
            resultSummary: "done",
            isTerminal: true,
            exitCode: 0,
            isRunning: false,
            output: output
        )))

        let renderedOutput = model.sections.first { $0.label == .output }?.value
        #expect(renderedOutput != nil)
        #expect(renderedOutput?.hasPrefix("0123456789") == true)
        #expect(renderedOutput?.contains("Detail truncated for performance") == true)
        #expect((renderedOutput?.count ?? 0) < output.count)
    }

    @Test("activity timeline presentation caps instantiated detail rows")
    func activityTimelinePresentationCapsInstantiatedRows() {
        let journal = JournalID(rawValue: "detail")
        let items = (0..<5).map { index in
            TranscriptActivityItem(
                id: .entry(journalID: journal, seq: EntrySeq(rawValue: index + 1)),
                kind: .unknown("event"),
                summary: "Event \(index)",
                isRunning: false,
                sourceEntry: nil
            )
        }
        let details = TranscriptActivityDetails(
            turnID: TranscriptTurnID(journalID: journal, promptSeq: nil, segmentAnchorSeq: EntrySeq(rawValue: 1)),
            summary: TranscriptActivitySummary(
                editedFileCount: 0,
                readFileCount: 0,
                searchedCode: false,
                listedFiles: false,
                commandCount: 0,
                eventCount: items.count,
                items: items
            )
        )

        let presentation = TranscriptActivityTimelinePresentation(details: details, itemLimit: 3)

        #expect(presentation.models.map(\.title) == ["Event 0", "Event 1", "Event 2"])
        #expect(presentation.omittedCount == 2)
    }

    @Test("activity timeline presentation disambiguates duplicate source identities")
    func activityTimelinePresentationDisambiguatesDuplicateSourceIdentities() {
        let journal = JournalID(rawValue: "detail")
        let duplicateID = TranscriptRowID.entry(journalID: journal, seq: EntrySeq(rawValue: 7))
        let items = [
            TranscriptActivityItem(
                id: duplicateID,
                kind: .tool,
                summary: "Processed 1 event",
                isRunning: false,
                sourceEntry: nil
            ),
            TranscriptActivityItem(
                id: duplicateID,
                kind: .attachment,
                summary: "Hook_Success attachment",
                isRunning: false,
                sourceEntry: nil
            ),
        ]
        let details = TranscriptActivityDetails(
            turnID: TranscriptTurnID(journalID: journal, promptSeq: nil, segmentAnchorSeq: EntrySeq(rawValue: 1)),
            summary: TranscriptActivitySummary(
                editedFileCount: 0,
                readFileCount: 0,
                searchedCode: false,
                listedFiles: false,
                commandCount: 0,
                eventCount: items.count,
                items: items
            )
        )

        let presentation = TranscriptActivityTimelinePresentation(details: details)

        #expect(presentation.models.map(\.sourceID) == [duplicateID, duplicateID])
        #expect(Set(presentation.models.map(\.id)).count == presentation.models.count)
        #expect(presentation.models.map(\.id.description) == [
            "entry:detail:7#0",
            "entry:detail:7#1",
        ])
    }

    private static func model(payload: EntryPayload) -> TranscriptActivityDetailModel {
        model(payload: payload, itemKind: .tool, itemSummary: "summary")
    }

    private static func model(
        payload: EntryPayload,
        itemKind: TranscriptActivityKind,
        itemSummary: String
    ) -> TranscriptActivityDetailModel {
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
            kind: itemKind,
            summary: itemSummary,
            isRunning: false,
            sourceEntry: entry
        )
        return TranscriptActivityDetailModel(item: item)
    }
}
