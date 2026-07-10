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
    func proseGroupingFollowsRoleAndTickWindow() throws {
        let rows = projector.project(TranscriptProjectionInput(
            entries: [
                Self.agent(seq: 1, text: "one"),
                Self.agent(seq: 2, text: "two"),
                Self.user(seq: 3, text: "three"),
                Self.agent(seq: 4, text: "four"),
            ],
            displayTick: { entry in entry.seq.rawValue == 4 ? 200 : entry.seq.rawValue * 10 },
            dayKey: { _ in "today" }
        )).rows

        let first = try #require(rows.row(seq: 1))
        let second = try #require(rows.row(seq: 2))
        let third = try #require(rows.row(seq: 3))
        let fourth = try #require(rows.row(seq: 4))

        #expect(first.agentGrouping == .first)
        #expect(second.agentGrouping == .last)
        #expect(third.userGrouping == .single)
        #expect(fourth.agentGrouping == .single)

        let tickTable: [(distance: Int, expected: [TranscriptProseGrouping])] = [
            (60, [.first, .last]),
            (61, [.single, .single]),
        ]
        for testCase in tickTable {
            let distance = testCase.distance
            let tableRows = projector.project(TranscriptProjectionInput(
                entries: [Self.agent(seq: 1, text: "one"), Self.agent(seq: 2, text: "two")],
                displayTick: { entry in entry.seq.rawValue == 1 ? 0 : distance },
                dayKey: { _ in "today" }
            )).rows

            #expect(tableRows.row(seq: 1)?.agentGrouping == testCase.expected[0])
            #expect(tableRows.row(seq: 2)?.agentGrouping == testCase.expected[1])
        }
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

    private static func entry(seq: Int, payload: EntryPayload) -> EntrySnapshot {
        EntrySnapshot(
            journalID: journal,
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
}

private extension TranscriptRow {
    var agentGrouping: TranscriptProseGrouping? {
        if case .proseAgent(_, let grouping) = rowKind {
            return grouping
        }
        return nil
    }

    var userGrouping: TranscriptProseGrouping? {
        if case .proseUser(_, _, let grouping) = rowKind {
            return grouping
        }
        return nil
    }
}
