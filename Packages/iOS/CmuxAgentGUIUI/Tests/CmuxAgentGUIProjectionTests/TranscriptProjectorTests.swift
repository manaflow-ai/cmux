import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation
import Testing

@Suite
struct TranscriptProjectorTests {
    private let projector = TranscriptProjector()

    @Test
    func appendOneToLargeWindowHasSmallDiff() {
        let previousInput = TranscriptProjectionInput(entries: Self.entries(count: 500))
        let previous = projector.project(previousInput)
        let nextInput = TranscriptProjectionInput(entries: Self.entries(count: 501))
        let next = projector.project(nextInput, previousRows: previous.rows)

        #expect(next.diff.inserted[.entry(journalID: Self.journal, seq: EntrySeq(rawValue: 501))] == 0)
        #expect(next.diff.appliedOperationCount <= 3)
    }

    @Test
    func burstAppendUsesFiveNewIdentitiesWithoutReplacingExistingRows() {
        let previous = projector.project(TranscriptProjectionInput(entries: Self.entries(count: 220)))
        let next = projector.project(
            TranscriptProjectionInput(entries: Self.entries(count: 225)),
            previousRows: previous.rows
        )
        let insertedIDs = Set((221...225).map { seq in
            TranscriptRowID.entry(journalID: Self.journal, seq: EntrySeq(rawValue: seq))
        })

        #expect(Set(next.diff.inserted.keys) == insertedIDs)
        #expect(next.diff.removed.isEmpty)
        #expect(next.diff.updated.isEmpty)
        #expect(Set(previous.rows.map(\.rowID)).isSubset(of: Set(next.rows.map(\.rowID))))
    }

    @Test
    func promptKeepsInterleavedAssistantProseAndActivityInOrder() throws {
        let rows = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.agent(seq: 2, text: "draft"),
            Self.tool(seq: 3, name: "rg", detail: "Theme"),
            Self.agent(seq: 4, text: "final"),
        ])).rows
        let summaryRow = try #require(rows.first { if case .activitySummary = $0.rowKind { true } else { false } })
        let expectedTurn = TranscriptTurnID(
            journalID: Self.journal,
            promptSeq: EntrySeq(rawValue: 1),
            segmentAnchorSeq: EntrySeq(rawValue: 1)
        )

        #expect(summaryRow.rowID == .activitySummary(expectedTurn))
        #expect(summaryRow.turnID == expectedTurn)
        guard case .activitySummary(let summary) = summaryRow.rowKind else { return }
        #expect(summary.items.map(\.id) == [
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 3)),
        ])
        #expect(rows.reversed().map(\.rowID) == [
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 1)),
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 2)),
            .activitySummary(expectedTurn),
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 4)),
        ])
        #expect(rows.row(seq: 2)?.agentText == "draft")
        #expect(rows.row(seq: 4)?.turnID == expectedTurn)
        #expect(rows.row(seq: 4)?.endsTurn == true)
    }

    @Test
    func adjacentAssistantProseBlocksBothRenderAsProseRows() {
        let rows = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.agent(seq: 2, text: "prose A"),
            Self.agent(seq: 3, text: "prose B"),
        ])).rows

        #expect(rows.row(seq: 2)?.agentText == "prose A")
        #expect(rows.row(seq: 3)?.agentText == "prose B")
        #expect(!rows.contains { if case .activitySummary = $0.rowKind { true } else { false } })
    }

    @Test
    func appendingAssistantProseRetainsExistingProseIdentity() throws {
        let first = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.agent(seq: 2, text: "prose A"),
        ]))
        let second = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.agent(seq: 2, text: "prose A"),
            Self.agent(seq: 3, text: "prose B"),
        ]), previousRows: first.rows)
        let retainedID = TranscriptRowID.entry(
            journalID: Self.journal,
            seq: EntrySeq(rawValue: 2)
        )
        let appendedID = TranscriptRowID.entry(
            journalID: Self.journal,
            seq: EntrySeq(rawValue: 3)
        )

        #expect(try #require(first.rows.row(seq: 2)).rowID == retainedID)
        #expect(try #require(second.rows.row(seq: 2)).rowID == retainedID)
        #expect(second.rows.row(seq: 2)?.agentText == "prose A")
        #expect(second.diff.removed.isEmpty)
        #expect(second.diff.inserted[appendedID] != nil)
    }

    @Test
    func preludeUsesStableJournalIdentityAndKeepsFinalAnswerVisible() throws {
        let rows = projector.project(TranscriptProjectionInput(entries: [
            Self.tool(seq: 1, name: "ls", detail: "Sources"),
            Self.agent(seq: 2, text: "answer"),
        ])).rows
        let prelude = TranscriptTurnID(
            journalID: Self.journal,
            promptSeq: nil,
            segmentAnchorSeq: EntrySeq(rawValue: 1)
        )

        #expect(rows.contains { $0.rowID == .activitySummary(prelude) })
        #expect(rows.row(seq: 2)?.turnID == prelude)
        #expect(rows.row(seq: 2)?.agentText == "answer")
    }

    @Test
    func latestTurnDoesNotBorrowPromptIdentityFromAnOlderJournal() {
        let olderJournal = JournalID(rawValue: "older")
        let latestJournal = JournalID(rawValue: "latest")
        let rows = projector.project(TranscriptProjectionInput(entries: [
            Self.entry(seq: 1, journalID: olderJournal, payload: .userMessage(UserMessagePayload(
                text: "old prompt",
                attachmentCount: 0,
                hasImage: false
            ))),
            Self.entry(seq: 2, journalID: latestJournal, payload: .toolRun(ToolRunPayload(
                toolName: "bash",
                argumentSummary: "work",
                isTerminal: true,
                isRunning: true
            ))),
        ], sessionPhase: .working))

        let latestTurn = TranscriptTurnID(
            journalID: latestJournal,
            promptSeq: nil,
            segmentAnchorSeq: EntrySeq(rawValue: 2)
        )
        #expect(rows.rows.contains { $0.turnID == latestTurn })
        #expect(!rows.rows.contains { row in
            row.turnID?.journalID == latestJournal && row.turnID?.promptSeq == EntrySeq(rawValue: 1)
        })
    }

    @Test
    func runningActivityRemainsVisibleAndKeepsEntryIdentity() {
        let rows = projector.project(TranscriptProjectionInput(
            entries: [
                Self.user(seq: 1, text: "prompt"),
                Self.tool(seq: 2, name: "bash", detail: "swift test", isRunning: true),
            ],
            sessionPhase: .working
        )).rows

        #expect(rows.contains { row in
            row.rowID == .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 2))
                && { if case .activityItem(let item) = row.rowKind { item.isRunning } else { false } }()
        })
        #expect(!rows.contains { if case .activitySummary = $0.rowKind { true } else { false } })
    }

    @Test
    func liveTurnKeepsPromptIdentityAcrossHole() {
        let hole = EntryRange(lowerBound: EntrySeq(rawValue: 3), upperBound: EntrySeq(rawValue: 4))
        let rows = projector.project(TranscriptProjectionInput(
            entries: [
                Self.user(seq: 1, text: "prompt"),
                Self.tool(seq: 2, name: "rg", detail: "before hole"),
                Self.tool(seq: 5, name: "bash", detail: "after hole"),
            ],
            holes: [hole],
            sessionPhase: .working
        )).rows
        let liveTurn = TranscriptTurnID(
            journalID: Self.journal,
            promptSeq: EntrySeq(rawValue: 1),
            segmentAnchorSeq: EntrySeq(rawValue: 5)
        )

        #expect(rows.row(seq: 5)?.turnID == liveTurn)
        #expect(rows.row(seq: 5)?.isActivityItem == true)
        #expect(rows.row(seq: 2) == nil)
        #expect(rows.activitySummaries.flatMap(\.items).map(\.id).contains(
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 2))
        ))
    }

    @Test
    func noPromptPreludeSegmentsAcrossHoleBothRender() {
        let hole = EntryRange(lowerBound: EntrySeq(rawValue: 2), upperBound: EntrySeq(rawValue: 4))
        let rows = projector.project(TranscriptProjectionInput(
            entries: [
                Self.tool(seq: 1, name: "rg", detail: "first prelude segment"),
                Self.tool(seq: 5, name: "ls", detail: "second prelude segment"),
            ],
            holes: [hole]
        )).rows

        #expect(rows.activitySummaries.count == 2)
        #expect(Set(rows.activitySummaries.compactMap { $0.turnID }).count == 2)
        #expect(Set(rows.activitySummaries.flatMap(\.items).map(\.id)) == Set([
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 1)),
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 5)),
        ]))
        #expect(rows.activitySummaries.allSatisfy { $0.turnID?.promptSeq == nil })
    }

    @Test
    func idlePromptedTurnAcrossHoleKeepsBothActivitySegments() {
        let hole = EntryRange(lowerBound: EntrySeq(rawValue: 3), upperBound: EntrySeq(rawValue: 4))
        let input = TranscriptProjectionInput(
            entries: [
                Self.user(seq: 1, text: "prompt"),
                Self.tool(seq: 2, name: "rg", detail: "before hole"),
                Self.tool(seq: 5, name: "ls", detail: "after hole"),
            ],
            holes: [hole]
        )
        let first = projector.project(input)
        let rows = first.rows

        #expect(rows.activitySummaries.count == 2)
        #expect(Set(rows.activitySummaries.compactMap { $0.turnID }).count == 2)
        #expect(Set(rows.activitySummaries.flatMap(\.items).map(\.id)) == Set([
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 2)),
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 5)),
        ]))
        #expect(rows.activitySummaries.allSatisfy {
            $0.turnID?.promptSeq == EntrySeq(rawValue: 1)
        })
        let second = projector.project(input, previousRows: rows)
        #expect(second.rows.map(\.rowID) == rows.map(\.rowID))
        #expect(second.diff.appliedOperationCount == 0)
    }

    @Test
    func idlePromptedTurnAcrossDayHeaderKeepsBothActivitySegments() {
        let rows = projector.project(TranscriptProjectionInput(
            entries: [
                Self.user(seq: 1, text: "prompt"),
                Self.tool(seq: 2, name: "rg", detail: "first day"),
                Self.tool(seq: 3, name: "ls", detail: "second day"),
            ],
            dayKey: { tick in tick < 3 ? "first day" : "second day" }
        )).rows

        #expect(rows.activitySummaries.count == 2)
        #expect(Set(rows.activitySummaries.compactMap { $0.turnID }).count == 2)
        #expect(Set(rows.activitySummaries.flatMap(\.items).map(\.id)) == Set([
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 2)),
            .entry(journalID: Self.journal, seq: EntrySeq(rawValue: 3)),
        ]))
    }

    @Test
    func completedActivitySummarizesDeterministicallyAndUnknownFailsOpen() throws {
        let rows = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.tool(seq: 2, name: "rg", detail: "Theme"),
            Self.file(seq: 3, path: "Theme.swift"),
            Self.tool(seq: 4, name: "apply_patch", detail: "Theme.swift"),
            Self.unknown(seq: 5, rawKind: "future-event"),
        ])).rows
        let row = try #require(rows.first { if case .activitySummary = $0.rowKind { true } else { false } })
        guard case .activitySummary(let summary) = row.rowKind else { return }

        #expect(summary.commandCount == 2)
        #expect(summary.searchedCode)
        #expect(summary.editedFileCount == 1)
        #expect(summary.eventCount == 0)
        #expect(summary.items.last?.kind == .unknown)
        #expect(Set(summary.items.map(\.id)).count == summary.items.count)
    }

    @Test
    func pendingTicketsAndStreamingAreNewestRows() throws {
        let firstTicket = SendTicket(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionID: AgentSessionID(rawValue: "session"),
            text: "queued first",
            attachmentCount: 0,
            state: .queuedLocal,
            createdAt: 10
        )
        let secondTicket = SendTicket(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            sessionID: AgentSessionID(rawValue: "session"),
            text: "queued second",
            attachmentCount: 0,
            state: .acceptedByMac,
            createdAt: 20
        )
        let rows = projector.project(TranscriptProjectionInput(
            entries: [Self.agent(seq: 1, text: "confirmed")],
            sendTickets: [firstTicket, secondTicket],
            streamingTail: TranscriptStreamingTail(
                journalID: Self.journal,
                afterSeq: EntrySeq(rawValue: 1),
                textTail: "streaming",
                revision: 1
            )
        )).rows

        #expect(rows[0].rowID == TranscriptRowID.streaming(
            journalID: Self.journal,
            afterSeq: EntrySeq(rawValue: 1)
        ))
        #expect(rows[1].rowID == TranscriptRowID.pendingTicket(secondTicket.id))
        #expect(rows[2].rowID == TranscriptRowID.pendingTicket(firstTicket.id))
        #expect(rows.filter { row in
            if case .streaming = row.rowKind {
                return true
            }
            return false
        }.count == 1)
        #expect(rows.contains {
            $0.rowID == TranscriptRowID.entry(journalID: Self.journal, seq: EntrySeq(rawValue: 1))
        })
    }

    @Test
    func activeAskProjectsOrderedActionableOptions() throws {
        let ask = PendingAsk(
            id: "ask-1",
            sessionID: AgentSessionID(rawValue: "session"),
            kind: .question,
            promptSummary: "Pick one",
            options: ["A", "B"],
            state: .active
        )
        let rows = projector.project(TranscriptProjectionInput(entries: [], asks: [ask])).rows
        let row = try #require(rows.first)

        #expect(row.rowID == .pendingAsk("ask-1"))
        guard case .pendingAsk(let projected) = row.rowKind else {
            Issue.record("active ask should remain actionable")
            return
        }
        #expect(projected.options == ["A", "B"])
    }

    @Test
    func streamingUpdatesKeepStableIdentity() throws {
        let firstInput = TranscriptProjectionInput(
            entries: [Self.agent(seq: 1, text: "confirmed")],
            streamingTail: TranscriptStreamingTail(
                journalID: Self.journal,
                afterSeq: EntrySeq(rawValue: 1),
                textTail: "first tail",
                revision: 1
            )
        )
        let first = projector.project(firstInput)
        let second = projector.project(TranscriptProjectionInput(
            entries: firstInput.entries,
            streamingTail: TranscriptStreamingTail(
                journalID: Self.journal,
                afterSeq: EntrySeq(rawValue: 1),
                textTail: "expanded tail",
                revision: 2
            )
        ), previousRows: first.rows)
        let streamingID = TranscriptRowID.streaming(
            journalID: Self.journal,
            afterSeq: EntrySeq(rawValue: 1)
        )

        #expect(try #require(first.rows.first).rowID == streamingID)
        #expect(try #require(second.rows.first).rowID == streamingID)
        #expect(second.diff.updated == Set([streamingID]))
        #expect(second.diff.inserted.isEmpty)
        #expect(second.diff.removed.isEmpty)
    }

    @Test
    func holesAndBoundaryRowsAreProjected() {
        let hole = EntryRange(lowerBound: EntrySeq(rawValue: 2), upperBound: EntrySeq(rawValue: 4))
        let rows = projector.project(TranscriptProjectionInput(
            entries: [
                Self.user(seq: 1, text: "before"),
                Self.agent(seq: 5, text: "after"),
            ],
            holes: [hole],
            hasMoreBefore: true
        )).rows

        #expect(rows.contains { $0.rowID == .hole(hole) })
        #expect(rows.last?.rowID == .boundary)
    }

    @Test
    func rowIDsRemainStableAcrossReprojection() {
        let input = TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "hello"),
            Self.agent(seq: 2, text: "world"),
        ])
        let first = projector.project(input)
        let second = projector.project(input, previousRows: first.rows)

        #expect(first.rows.map(\.rowID) == second.rows.map(\.rowID))
        #expect(second.diff.appliedOperationCount == 0)
    }

    @Test
    func productionProjectionOmitsDateHeadersWithoutRealTimestamps() {
        let rows = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "hello"),
            Self.agent(seq: 2, text: "world"),
        ])).rows

        #expect(!rows.contains { row in
            if case .dateHeader = row.rowKind { return true }
            return false
        })
    }

    @Test
    func nonMonotonicDayKeysAreDeduplicatedWithoutTrapping() {
        let input = TranscriptProjectionInput(
            entries: [
                Self.user(seq: 1, text: "first"),
                Self.agent(seq: 2, text: "second"),
                Self.user(seq: 3, text: "third"),
            ],
            dayKey: { tick in tick == 2 ? "tomorrow" : "today" }
        )
        let first = projector.project(input)
        let dateHeaders = first.rows.compactMap { row -> TranscriptRowID? in
            if case .dateHeader = row.rowKind {
                return row.rowID
            }
            return nil
        }

        #expect(dateHeaders == [.dateHeader("tomorrow"), .dateHeader("today")])
        #expect(Set(first.rows.map(\.rowID)).count == first.rows.count)

        let second = projector.project(input, previousRows: first.rows + [first.rows[0]])
        #expect(Set(second.rows.map(\.rowID)).count == second.rows.count)
    }

    private static let journal = JournalID(rawValue: "journal")

    private static func entries(count: Int) -> [EntrySnapshot] {
        (1...count).map { seq in
            seq.isMultiple(of: 2) ? agent(seq: seq, text: "agent \(seq)") : user(seq: seq, text: "user \(seq)")
        }
    }

    private static func agent(seq: Int, text: String) -> EntrySnapshot {
        entry(seq: seq, payload: .agentProse(AgentProsePayload(markdown: text)))
    }

    private static func user(seq: Int, text: String) -> EntrySnapshot {
        entry(seq: seq, payload: .userMessage(UserMessagePayload(text: text, attachmentCount: 0, hasImage: false)))
    }

    private static func tool(seq: Int, name: String, detail: String, isRunning: Bool = false) -> EntrySnapshot {
        entry(seq: seq, payload: .toolRun(ToolRunPayload(
            toolName: name,
            argumentSummary: detail,
            isTerminal: name == "bash",
            isRunning: isRunning
        )))
    }

    private static func file(seq: Int, path: String) -> EntrySnapshot {
        entry(seq: seq, payload: .fileChange(FileChangePayload(path: path, changeKind: .edit)))
    }

    private static func unknown(seq: Int, rawKind: String) -> EntrySnapshot {
        entry(seq: seq, payload: .unknown(UnknownPayload(rawKind: rawKind, summary: "preserved")))
    }

    private static func entry(seq: Int, journalID: JournalID = Self.journal, payload: EntryPayload) -> EntrySnapshot {
        EntrySnapshot(
            journalID: journalID,
            seq: EntrySeq(rawValue: seq),
            kind: payload.kind,
            content: EntryContent(contentHash: seq, payload: payload),
            version: EntityVersion(rawValue: UInt64(seq))
        )
    }
}

private extension [TranscriptRow] {
    func row(seq: Int) -> TranscriptRow? {
        first { $0.rowID == .entry(journalID: JournalID(rawValue: "journal"), seq: EntrySeq(rawValue: seq)) }
    }

    var activitySummaries: [(turnID: TranscriptTurnID?, items: [TranscriptActivityItem])] {
        compactMap { row in
            guard case .activitySummary(let summary) = row.rowKind else { return nil }
            return (turnID: row.turnID, items: summary.items)
        }
    }
}

private extension TranscriptRow {
    var isActivityItem: Bool {
        if case .activityItem = rowKind {
            return true
        }
        return false
    }

    var agentText: String? {
        if case .proseAgent(let text, _) = rowKind {
            return text
        }
        return nil
    }

    var agentGrouping: TranscriptProseGrouping? {
        if case .proseAgent(_, let grouping) = rowKind {
            return grouping
        }
        return nil
    }

    var userGrouping: TranscriptProseGrouping? {
        if case .proseUser(_, _, let grouping, _, _) = rowKind {
            return grouping
        }
        return nil
    }
}
