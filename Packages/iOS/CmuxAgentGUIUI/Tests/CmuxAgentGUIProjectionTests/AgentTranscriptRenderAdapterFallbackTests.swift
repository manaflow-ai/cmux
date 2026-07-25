import CmuxAgentReplica
import Testing

@testable import CmuxAgentGUIUI

@Suite("Agent transcript fallback title rendering")
struct AgentTranscriptFallbackTitleTests {
    @Test("fallback activity titles prefer useful summaries over raw event kinds")
    func fallbackActivityTitlesPreferUsefulSummaries() {
        let title = AgentGUIL10n.compactActivityTitle(
            kindLabel: "future_agent_internal_signal",
            summary: "Indexed 12 files"
        )

        #expect(title == "Indexed 12 files")
        #expect(!title.contains("future_agent_internal_signal"))
    }

    @Test("fallback activity titles without summaries only show known useful kinds")
    func fallbackActivityTitlesWithoutSummariesOnlyShowKnownUsefulKinds() {
        #expect(AgentGUIL10n.compactActivityTitle(kindLabel: "command", summary: "") == "Command")
        #expect(AgentGUIL10n.compactActivityTitle(
            kindLabel: "future_agent_internal_signal",
            summary: ""
        ) == "Activity")
    }

    @Test("unsupported titles never fall back to raw event kinds")
    func unsupportedTitlesNeverFallBackToRawEventKinds() {
        let withSummary = AgentGUIL10n.compactUnsupportedTitle(
            rawKind: "future_agent_internal_signal",
            summary: "Generated an image preview"
        )
        let withoutSummary = AgentGUIL10n.compactUnsupportedTitle(
            rawKind: "future_agent_internal_signal",
            summary: "future_agent_internal_signal"
        )

        #expect(withSummary == "Generated an image preview")
        #expect(!withSummary.contains("future_agent_internal_signal"))
        #expect(withoutSummary == "Activity")
    }

    @Test("future status titles use detail or localized status instead of raw codes")
    func futureStatusTitlesUseDetailOrLocalizedStatus() {
        let withDetail = AgentGUIL10n.compactStatusTitle(
            code: .other("future_agent_status"),
            detail: "Waiting for approval"
        )
        let withoutUsefulDetail = AgentGUIL10n.compactStatusTitle(
            code: .other("future_agent_status"),
            detail: "future_agent_status"
        )

        #expect(withDetail == "Waiting for approval")
        #expect(!withDetail.contains("future_agent_status"))
        #expect(withoutUsefulDetail == "Status")
    }
}

#if os(iOS)
import CmuxAgentGUIProjection

@Suite("Agent transcript fallback row rendering")
struct AgentTranscriptRenderAdapterFallbackTests {
    @Test("generic activity rows prefer useful summaries over raw event kinds")
    func genericActivityRowsPreferUsefulSummaries() throws {
        let row = Self.row(.genericActivity(TranscriptGenericActivity(
            kindLabel: "future_agent_internal_signal",
            summary: "Indexed 12 files"
        )))

        let metadata = try Self.metadata(from: row)

        #expect(metadata == "Indexed 12 files")
        #expect(!metadata.contains("future_agent_internal_signal"))
        #expect(row.accessibilityLabel == "Indexed 12 files")
    }

    @Test("generic activity rows without a summary only show known useful kinds")
    func genericActivityRowsWithoutSummaryOnlyShowKnownUsefulKinds() throws {
        let command = Self.row(.genericActivity(TranscriptGenericActivity(
            kindLabel: "command",
            summary: ""
        )))
        let unknown = Self.row(.genericActivity(TranscriptGenericActivity(
            kindLabel: "future_agent_internal_signal",
            summary: ""
        )))

        #expect(try Self.metadata(from: command) == "Command")
        #expect(try Self.metadata(from: unknown) == "Activity")
        #expect(unknown.accessibilityLabel == "Activity")
    }

    @Test("unsupported rows do not expose raw event kinds as transcript titles")
    func unsupportedRowsDoNotExposeRawEventKindsAsTitles() throws {
        let withSummary = Self.row(.unsupported(
            rawKind: "future_agent_internal_signal",
            summary: "Generated an image preview"
        ))
        let withoutSummary = Self.row(.unsupported(
            rawKind: "future_agent_internal_signal",
            summary: "future_agent_internal_signal"
        ))

        #expect(try Self.metadata(from: withSummary) == "Generated an image preview")
        #expect(!((try Self.metadata(from: withSummary)).contains("future_agent_internal_signal")))
        #expect(try Self.metadata(from: withoutSummary) == "Activity")
        #expect(withoutSummary.accessibilityLabel == "Activity")
    }

    @Test("future status rows use detail or a localized status title instead of raw codes")
    func futureStatusRowsUseDetailOrLocalizedStatusTitle() throws {
        let withDetail = Self.row(.status(
            code: .other("future_agent_status"),
            detail: "Waiting for approval"
        ))
        let withoutUsefulDetail = Self.row(.status(
            code: .other("future_agent_status"),
            detail: "future_agent_status"
        ))

        #expect(try Self.metadata(from: withDetail) == "Waiting for approval")
        #expect(!((try Self.metadata(from: withDetail)).contains("future_agent_status")))
        #expect(try Self.metadata(from: withoutUsefulDetail) == "Status")
        #expect(withoutUsefulDetail.accessibilityLabel == "Status")
    }

    private static func row(_ kind: TranscriptRowKind) -> TranscriptRow {
        TranscriptRow(
            rowID: .entry(
                journalID: JournalID(rawValue: "fallback-rows"),
                seq: EntrySeq(rawValue: 1)
            ),
            rowKind: kind
        )
    }

    private static func metadata(from row: TranscriptRow) throws -> String {
        let rendered = try #require(AgentTranscriptRenderAdapter().rows(from: [row]).first)
        guard case .metadata(let value) = rendered.content else {
            Issue.record("Expected a metadata render row")
            throw AgentTranscriptRenderAdapterFallbackTestError.expectedMetadata
        }
        return value
    }
}

private enum AgentTranscriptRenderAdapterFallbackTestError: Error {
    case expectedMetadata
}
#endif
