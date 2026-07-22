@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation
import Testing
#if os(iOS)
import UIKit
#endif

@Suite
struct TranscriptProjectorCatalogTests {
    private let projector = TranscriptProjector()

    @Test
    func noiseOnlyActivityIsSuppressedAndStaysSuppressedAcrossUnrelatedAppends() {
        let firstEntries = [
            Self.user(seq: 1, text: "prompt"),
            Self.entry(seq: 2, payload: .unknown(UnknownPayload(
                rawKind: "internal_bookkeeping",
                rawJSON: #"{"private":true}"#
            ))),
            Self.entry(seq: 3, payload: .status(StatusPayload(code: .compacted))),
        ]
        let first = projector.project(TranscriptProjectionInput(entries: firstEntries))

        #expect(first.rows.allSatisfy { !$0.isActivityRow })
        #expect(first.rows.map(\.rowID) == [.entry(journalID: Self.journal, seq: EntrySeq(rawValue: 1))])

        let second = projector.project(
            TranscriptProjectionInput(entries: firstEntries + [
                Self.user(seq: 4, text: "unrelated prompt"),
                Self.agent(seq: 5, text: "answer"),
            ]),
            previousRows: first.rows
        )

        #expect(second.rows.allSatisfy { row in
            row.rowID != .activitySummary(Self.turn(promptSeq: 1))
                && row.rowID != .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 2))
                && row.rowID != .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 3))
        })
        #expect(second.diff.removed.isEmpty)
        #expect(second.rows.contains { $0.rowID == first.rows[0].rowID })
    }

    @Test
    func meaningfulActivityKeepsUnknownDetailsGenericWithoutRawKindOrJSON() throws {
        let secretKind = "future_secret_record_kind"
        let secretJSON = #"{"secret":"payload"}"#
        let rows = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.tool(seq: 2, exitCode: 0),
            Self.entry(seq: 3, payload: .unknown(UnknownPayload(
                rawKind: secretKind,
                rawJSON: secretJSON
            ))),
        ])).rows
        let summary = try #require(rows.activitySummaries.first)
        let unknown = try #require(summary.items.last)

        #expect(AgentGUIL10n.activityKind(unknown.kind) == AgentGUIL10n.string(
            "agent.activity.event",
            defaultValue: "Event"
        ))
        #expect(!unknown.summary.contains(secretKind))
        #expect(!unknown.summary.contains(secretJSON))
    }

    @Test
    func freshTailHoleIsSuppressedAcrossStreamingAppendsButMidHistoryHoleRemains() {
        let hole = EntryRange(lowerBound: EntrySeq(rawValue: 1), upperBound: EntrySeq(rawValue: 4))
        let initial = projector.project(TranscriptProjectionInput(
            entries: [],
            holes: [hole],
            streamingTail: Self.tail(text: "starting", revision: 1)
        ))
        let updated = projector.project(TranscriptProjectionInput(
            entries: [],
            holes: [hole],
            streamingTail: Self.tail(text: "starting work", revision: 2)
        ), previousRows: initial.rows)

        #expect(!initial.rows.contains { $0.rowID == .hole(hole) })
        #expect(!updated.rows.contains { $0.rowID == .hole(hole) })
        #expect(initial.rows.map(\.rowID) == updated.rows.map(\.rowID))
        #expect(updated.diff.inserted.isEmpty)
        #expect(updated.diff.removed.isEmpty)

        let midHistory = projector.project(TranscriptProjectionInput(
            entries: [Self.user(seq: 5, text: "real content")],
            holes: [hole],
            streamingTail: Self.tail(text: "live tail", revision: 3)
        )).rows
        #expect(midHistory.contains { $0.rowID == .hole(hole) })
    }

    @Test
    func attachmentMetadataUpdatesTheSameUserRowIdentity() throws {
        let plain = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "message", attachmentCount: 0, hasImage: false),
        ]))
        let attached = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "message", attachmentCount: 3, hasImage: true),
        ]), previousRows: plain.rows)
        let plainRow = try #require(plain.rows.first)
        let attachedRow = try #require(attached.rows.first)

        #expect(attachedRow.rowID == plainRow.rowID)
        #expect(attachedRow != plainRow)
        #expect(attached.diff.updated == Set([plainRow.rowID]))
        #expect(attached.diff.inserted.isEmpty)
        #expect(attached.diff.removed.isEmpty)
    }

    @Test
    func nonzeroExitUpdatesTheSameLiveCommandIdentityAndCompletedSummaryReportsFailure() throws {
        let succeeded = projector.project(TranscriptProjectionInput(
            entries: [Self.user(seq: 1, text: "prompt"), Self.tool(seq: 2, exitCode: 0)],
            sessionPhase: .working
        ))
        let failed = projector.project(TranscriptProjectionInput(
            entries: [Self.user(seq: 1, text: "prompt"), Self.tool(seq: 2, exitCode: 2)],
            sessionPhase: .working
        ), previousRows: succeeded.rows)
        let succeededCommand = try #require(succeeded.rows.row(seq: 2))
        let failedCommand = try #require(failed.rows.row(seq: 2))

        #expect(failedCommand.rowID == succeededCommand.rowID)
        #expect(failedCommand != succeededCommand)
        #expect(failed.diff.updated.contains(failedCommand.rowID))

        let completed = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.tool(seq: 2, exitCode: 2),
        ])).rows
        let summary = try #require(completed.activitySummaries.first)
        #expect(AgentGUIL10n.activitySummary(summary).localizedCaseInsensitiveContains("1 failed"))
    }

    @Test
    func failedStatusesAreMeaningfulRailItemsWhileHistoricalAsksNeverBecomeCards() throws {
        let rows = projector.project(TranscriptProjectionInput(
            entries: [
                Self.user(seq: 1, text: "prompt"),
                Self.entry(seq: 2, payload: .status(StatusPayload(code: .apiError, detail: "offline"))),
                Self.entry(seq: 3, payload: .status(StatusPayload(code: .turnAborted))),
                Self.entry(seq: 4, payload: .question(QuestionPayload(
                    questionID: "historical-question",
                    prompt: "Choose",
                    options: ["A", "B"],
                    answeredChoice: 0
                ))),
                Self.entry(seq: 5, payload: .permission(PermissionPayload(
                    toolName: "Bash",
                    detail: "Run command",
                    options: ["Allow", "Deny"]
                ))),
            ],
            asks: [PendingAsk(
                id: "historical-question",
                sessionID: AgentSessionID(rawValue: "session"),
                kind: .question,
                promptSummary: "Choose",
                options: ["A", "B"],
                state: .answered(choice: 0)
            )],
            sessionPhase: .working
        )).rows
        let statusItems = rows.activityItems.filter { $0.kind == .status }

        #expect(statusItems.count == 2)
        #expect(statusItems.allSatisfy {
            AgentGUIL10n.activityAccessibility($0).localizedCaseInsensitiveContains("failed")
        })
        #expect(rows.activityItems.contains { $0.kind == .question })
        #expect(rows.activityItems.contains { $0.kind == .permission })
        #expect(!rows.contains { if case .pendingAsk = $0.rowKind { true } else { false } })
    }

    #if os(iOS)
    @Test
    func attachmentAndFailureRowsExposeDeterministicCatalogGlyphs() throws {
        let attachedRows = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "paper", attachmentCount: 2, hasImage: false),
            Self.user(seq: 2, text: "image", attachmentCount: 1, hasImage: true),
        ])).rows
        let paperLayout = Self.layout(try #require(attachedRows.row(seq: 1)))
        let imageLayout = Self.layout(try #require(attachedRows.row(seq: 2)))

        #expect(paperLayout.glyphElements.map(\.systemName) == ["paperclip"])
        #expect(paperLayout.textElements.contains { $0.attributedText.value.string == "2" })
        #expect(imageLayout.glyphElements.map(\.systemName) == ["paperclip", "photo"])
        #expect(imageLayout.textElements.contains { $0.attributedText.value.string == "1" })

        let failedRows = projector.project(TranscriptProjectionInput(
            entries: [Self.user(seq: 1, text: "prompt"), Self.tool(seq: 2, exitCode: 2)],
            sessionPhase: .working
        )).rows
        let failedLayout = Self.layout(try #require(failedRows.row(seq: 2)))
        #expect(failedLayout.glyphElements.map(\.systemName) == ["exclamationmark.circle.fill"])
        #expect(failedLayout.textElements.contains { $0.role == .error })
    }

    @Test
    func unsupportedLayoutUsesGenericEventLabelWithoutRawKind() throws {
        let rawKind = "private_future_kind"
        let row = TranscriptRow(
            rowID: .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 9)),
            rowKind: .unsupported(rawKind: rawKind, summary: "Safe summary")
        )
        let layout = Self.layout(row)
        let rendered = layout.textElements.map(\.attributedText.value.string).joined(separator: " ")

        #expect(rendered.contains(AgentGUIL10n.string("agent.activity.event", defaultValue: "Event")))
        #expect(!rendered.contains(rawKind))
    }
    #endif

    private static let journal = JournalID(rawValue: "catalog")

    private static func turn(promptSeq: Int) -> TranscriptTurnID {
        TranscriptTurnID(
            journalID: journal,
            promptSeq: EntrySeq(rawValue: promptSeq),
            segmentAnchorSeq: EntrySeq(rawValue: promptSeq)
        )
    }

    static func user(
        seq: Int,
        text: String,
        attachmentCount: Int = 0,
        hasImage: Bool = false
    ) -> EntrySnapshot {
        entry(seq: seq, payload: .userMessage(UserMessagePayload(
            text: text,
            attachmentCount: attachmentCount,
            hasImage: hasImage
        )))
    }

    private static func agent(seq: Int, text: String) -> EntrySnapshot {
        entry(seq: seq, payload: .agentProse(AgentProsePayload(markdown: text)))
    }

    static func tool(seq: Int, exitCode: Int?) -> EntrySnapshot {
        entry(seq: seq, payload: .toolRun(ToolRunPayload(
            toolName: "Bash",
            argumentSummary: "swift test",
            resultSummary: "result",
            isTerminal: true,
            exitCode: exitCode,
            isRunning: false
        )))
    }

    static func entry(seq: Int, payload: EntryPayload) -> EntrySnapshot {
        EntrySnapshot(
            journalID: journal,
            seq: EntrySeq(rawValue: seq),
            kind: payload.kind,
            content: EntryContent(contentHash: payload.stableHash, payload: payload),
            version: EntityVersion(rawValue: UInt64(seq))
        )
    }

    private static func tail(text: String, revision: Int) -> TranscriptStreamingTail {
        TranscriptStreamingTail(
            journalID: journal,
            afterSeq: EntrySeq(rawValue: 4),
            textTail: text,
            revision: revision
        )
    }

    #if os(iOS)
    private static func layout(_ row: TranscriptRow) -> TranscriptRowLayoutResult {
        TranscriptRowLayout.layout(
            row: row,
            width: 393,
            density: .comfortable,
            scale: 3
        )
    }
    #endif
}

private extension [TranscriptRow] {
    func row(seq: Int) -> TranscriptRow? {
        first { $0.rowID == .entry(
            journalID: JournalID(rawValue: "catalog"),
            seq: EntrySeq(rawValue: seq)
        ) }
    }

    var activitySummaries: [TranscriptActivitySummary] {
        compactMap { row in
            guard case .activitySummary(let summary) = row.rowKind else { return nil }
            return summary
        }
    }

    var activityItems: [TranscriptActivityItem] {
        compactMap { row in
            guard case .activityItem(let item) = row.rowKind else { return nil }
            return item
        }
    }
}

private extension TranscriptRow {
    var isActivityRow: Bool {
        switch rowKind {
        case .activityItem, .activitySummary, .genericActivity, .unsupported:
            true
        default:
            false
        }
    }
}

#if os(iOS)
extension TranscriptRenderingRegressionTests {
    static var slice3CatalogLayoutHarnessRows: [TranscriptRow] {
        let projector = TranscriptProjector()
        let attached = projector.project(TranscriptProjectionInput(entries: [
            TranscriptProjectorCatalogTests.user(seq: 20, text: "Two files", attachmentCount: 2),
            TranscriptProjectorCatalogTests.user(seq: 21, text: "One image", attachmentCount: 1, hasImage: true),
        ])).rows
        let failedLive = projector.project(TranscriptProjectionInput(
            entries: [
                TranscriptProjectorCatalogTests.user(seq: 30, text: "Run it"),
                TranscriptProjectorCatalogTests.tool(seq: 31, exitCode: 2),
                TranscriptProjectorCatalogTests.entry(
                    seq: 32,
                    payload: .status(StatusPayload(code: .apiError, detail: "offline"))
                ),
            ],
            sessionPhase: .working
        )).rows.filter { if case .activityItem = $0.rowKind { true } else { false } }
        let failedSummary = projector.project(TranscriptProjectionInput(entries: [
            TranscriptProjectorCatalogTests.user(seq: 40, text: "Run it"),
            TranscriptProjectorCatalogTests.tool(seq: 41, exitCode: 2),
        ])).rows.filter { if case .activitySummary = $0.rowKind { true } else { false } }
        return attached + failedLive + failedSummary
    }
}
#endif
