import Foundation
import Testing
@testable import CmuxAgentReplica

@MainActor @Suite struct ConversationReplicaTests {
    @Test func appendRequiresContiguousTailAndDuplicateIsDropped() {
        let store = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())

        store.apply(.entriesAppended(journalID: ReplicaTestSupport.journal, entries: [ReplicaTestSupport.entry(1), ReplicaTestSupport.entry(2)]), origin: .live)
        #expect(store.entries.map(\.seq) == [ReplicaTestSupport.seq(1), ReplicaTestSupport.seq(2)])
        #expect(store.tailSeq == ReplicaTestSupport.seq(2))

        store.apply(.entriesAppended(journalID: ReplicaTestSupport.journal, entries: [ReplicaTestSupport.entry(2, version: 2, hash: 200)]), origin: .resync)
        #expect(store.entries.map(\.content.contentHash) == [1, 2])
        #expect(!store.needsTailPull)
        #expect(store.lastAppliedOrigin == .live)

        store.apply(.entriesAppended(journalID: ReplicaTestSupport.journal, entries: [ReplicaTestSupport.entry(4)]), origin: .live)
        #expect(store.entries.map(\.seq) == [ReplicaTestSupport.seq(1), ReplicaTestSupport.seq(2)])
        #expect(store.tailSeq == ReplicaTestSupport.seq(4))
        #expect(store.needsTailPull)
        #expect(!store.unreadIsExact)
        #expect(store.holes == [EntryRange(lowerBound: ReplicaTestSupport.seq(3), upperBound: ReplicaTestSupport.seq(4))])
    }

    @Test func entryReplacementRequiresLoadedRangeAndHigherVersion() {
        let store = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())
        store.apply(.entriesAppended(journalID: ReplicaTestSupport.journal, entries: [ReplicaTestSupport.entry(1, version: 2)]), origin: .live)

        store.apply(.entryReplaced(ReplicaTestSupport.entry(1, version: 1, hash: 100)), origin: .live)
        #expect(store.entries.first?.content.contentHash == 1)
        store.apply(.entryReplaced(ReplicaTestSupport.entry(1, version: 3, hash: 300)), origin: .live)
        #expect(store.entries.first?.content.contentHash == 300)
        store.apply(.entryReplaced(ReplicaTestSupport.entry(5, version: 10, hash: 500)), origin: .live)
        #expect(store.entries.count == 1)
    }

    @Test func journalResetDropsWindowButKeepsTicketsAndReadPointer() {
        let ticketID = UUID()
        let store = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())
        store.apply(.entriesAppended(journalID: ReplicaTestSupport.journal, entries: [ReplicaTestSupport.entry(1), ReplicaTestSupport.entry(2)]), origin: .live)
        store.markReadThrough(ReplicaTestSupport.seq(2))
        store.apply(.sendTicketChanged(ReplicaTestSupport.ticket(id: ticketID, state: .queuedLocal, createdAt: 1)), origin: .live)

        store.apply(.journalReset(sessionID: ReplicaTestSupport.session, newJournal: ReplicaTestSupport.otherJournal, tailSeq: ReplicaTestSupport.seq(5)), origin: .live)

        #expect(store.journalID == ReplicaTestSupport.otherJournal)
        #expect(store.entries.isEmpty)
        #expect(store.sendTickets.map(\.id) == [ticketID])
        #expect(store.readPointer == ReplicaTestSupport.seq(2))
        #expect(store.resetMarkerCount == 1)
        #expect(store.needsTailPull)
        #expect(store.holes == [EntryRange(lowerBound: ReplicaTestSupport.seq(1), upperBound: ReplicaTestSupport.seq(5))])
    }

    @Test func mergePageCoalescesOverlapsAndKeepsHigherVersion() {
        let store = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())
        store.mergePage(
            journal: ReplicaTestSupport.journal,
            entries: [ReplicaTestSupport.entry(3, version: 1), ReplicaTestSupport.entry(4, version: 1)],
            windowStart: ReplicaTestSupport.seq(3),
            windowEnd: ReplicaTestSupport.seq(4),
            tailSeq: ReplicaTestSupport.seq(6),
            hasMoreBefore: true
        )
        store.mergePage(
            journal: ReplicaTestSupport.journal,
            entries: [ReplicaTestSupport.entry(2, version: 1), ReplicaTestSupport.entry(3, version: 2, hash: 30)],
            windowStart: ReplicaTestSupport.seq(2),
            windowEnd: ReplicaTestSupport.seq(3),
            tailSeq: ReplicaTestSupport.seq(6),
            hasMoreBefore: true
        )

        #expect(store.loadedRanges == [EntryRange(lowerBound: ReplicaTestSupport.seq(2), upperBound: ReplicaTestSupport.seq(4))])
        #expect(store.entries.map(\.content.contentHash) == [2, 30, 4])
        #expect(store.holes == [
            EntryRange(lowerBound: ReplicaTestSupport.seq(1), upperBound: ReplicaTestSupport.seq(1)),
            EntryRange(lowerBound: ReplicaTestSupport.seq(5), upperBound: ReplicaTestSupport.seq(6)),
        ])
    }

    @Test func newestPageWithOlderHistoryDoesNotRequestTheSameTailAgain() {
        let store = ConversationReplica(
            sessionID: ReplicaTestSupport.session,
            journalID: ReplicaTestSupport.journal,
            clock: ReplicaTestSupport.clock()
        )
        store.mergePage(
            journal: ReplicaTestSupport.journal,
            entries: (51...100).map { ReplicaTestSupport.entry($0) },
            windowStart: ReplicaTestSupport.seq(51),
            windowEnd: ReplicaTestSupport.seq(100),
            tailSeq: ReplicaTestSupport.seq(100),
            hasMoreBefore: true
        )

        #expect(store.holes == [
            EntryRange(lowerBound: ReplicaTestSupport.seq(1), upperBound: ReplicaTestSupport.seq(50)),
        ])
        #expect(!store.needsTailPull)
    }

    @Test func mergePageInterleavedWithDuplicateLiveAppendKeepsPulledWindow() {
        let store = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())
        store.mergePage(
            journal: ReplicaTestSupport.journal,
            entries: [ReplicaTestSupport.entry(1), ReplicaTestSupport.entry(2)],
            windowStart: ReplicaTestSupport.seq(1),
            windowEnd: ReplicaTestSupport.seq(2),
            tailSeq: ReplicaTestSupport.seq(2),
            hasMoreBefore: false
        )

        store.apply(.entriesAppended(journalID: ReplicaTestSupport.journal, entries: [
            ReplicaTestSupport.entry(1, version: 2, hash: 100),
            ReplicaTestSupport.entry(2, version: 2, hash: 200),
        ]), origin: .live)

        #expect(store.entries.map(\.content.contentHash) == [1, 2])
        #expect(store.tailSeq == ReplicaTestSupport.seq(2))
        #expect(store.lastAppliedOrigin == .resync)
    }

    @Test func epochColdConversationIgnoresUnrelatedAppend() {
        let store = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())
        store.handleEpochChange(to: ReplicaEpoch(rawValue: "e2"))

        store.apply(.entriesAppended(journalID: ReplicaTestSupport.otherJournal, entries: [
            ReplicaTestSupport.entry(1, journalID: ReplicaTestSupport.otherJournal),
        ]), origin: .live)

        #expect(store.journalID == nil)
        #expect(store.entries.isEmpty)
        #expect(store.lastAppliedOrigin == .resync)
    }

    @Test func evictionReinsertsHoleAndUnreadPausesAtHole() {
        let store = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, windowCap: 3, clock: ReplicaTestSupport.clock())
        store.apply(.entriesAppended(journalID: ReplicaTestSupport.journal, entries: [ReplicaTestSupport.entry(1), ReplicaTestSupport.entry(2), ReplicaTestSupport.entry(3), ReplicaTestSupport.entry(4), ReplicaTestSupport.entry(5)]), origin: .live)
        store.markReadThrough(ReplicaTestSupport.seq(1))

        #expect(store.entries.map(\.seq) == [ReplicaTestSupport.seq(3), ReplicaTestSupport.seq(4), ReplicaTestSupport.seq(5)])
        #expect(store.holes == [EntryRange(lowerBound: ReplicaTestSupport.seq(1), upperBound: ReplicaTestSupport.seq(2))])
        #expect(!store.unreadIsExact)
        #expect(store.unreadCount == 0)

        store.markReadThrough(ReplicaTestSupport.seq(2))
        #expect(store.unreadIsExact)
        #expect(store.unreadCount == 3)
    }

    @Test func loadingOlderHistoryRetainsTheRequestedPageAtTheWindowCap() {
        let store = ConversationReplica(
            sessionID: ReplicaTestSupport.session,
            journalID: ReplicaTestSupport.journal,
            windowCap: 3,
            clock: ReplicaTestSupport.clock()
        )
        store.mergePage(
            journal: ReplicaTestSupport.journal,
            entries: (100...102).map { ReplicaTestSupport.entry($0) },
            windowStart: ReplicaTestSupport.seq(100),
            windowEnd: ReplicaTestSupport.seq(102),
            tailSeq: ReplicaTestSupport.seq(102),
            hasMoreBefore: true
        )

        store.mergePage(
            journal: ReplicaTestSupport.journal,
            entries: (97...99).map { ReplicaTestSupport.entry($0) },
            windowStart: ReplicaTestSupport.seq(97),
            windowEnd: ReplicaTestSupport.seq(99),
            tailSeq: ReplicaTestSupport.seq(102),
            hasMoreBefore: true
        )

        #expect(store.entries.map(\.seq) == [
            ReplicaTestSupport.seq(97),
            ReplicaTestSupport.seq(98),
            ReplicaTestSupport.seq(99),
        ])
        #expect(store.loadedRanges == [
            EntryRange(lowerBound: ReplicaTestSupport.seq(97), upperBound: ReplicaTestSupport.seq(99)),
        ])
    }

    @Test func epochChangeKeepsTicketsAndReadPointerButDropsReplicatedWindow() {
        let store = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())
        let ticketID = UUID()
        store.apply(.entriesAppended(journalID: ReplicaTestSupport.journal, entries: [ReplicaTestSupport.entry(1)]), origin: .live)
        store.markReadThrough(ReplicaTestSupport.seq(1))
        store.apply(.sendTicketChanged(ReplicaTestSupport.ticket(id: ticketID, state: .queuedLocal, createdAt: 1)), origin: .live)
        store.apply(.askChanged(PendingAsk(id: "ask", sessionID: ReplicaTestSupport.session, kind: .question, promptSummary: "q", options: ["A", "B"], state: .active)), origin: .live)

        store.handleEpochChange(to: ReplicaEpoch(rawValue: "e2"))

        #expect(store.journalID == nil)
        #expect(store.entries.isEmpty)
        #expect(store.asks.isEmpty)
        #expect(store.sendTickets.count == 1)
        #expect(store.readPointer == ReplicaTestSupport.seq(1))
    }

    @Test func cursorPagingTreatsSparseByteOffsetsAsObservedEntries() {
        let store = ConversationReplica(
            sessionID: ReplicaTestSupport.session,
            journalID: ReplicaTestSupport.journal,
            clock: ReplicaTestSupport.clock()
        )
        store.mergePage(
            journal: ReplicaTestSupport.journal,
            entries: [ReplicaTestSupport.entry(1_024), ReplicaTestSupport.entry(8_192)],
            windowStart: ReplicaTestSupport.seq(1_024),
            windowEnd: ReplicaTestSupport.seq(8_192),
            tailSeq: ReplicaTestSupport.seq(8_192),
            hasMoreBefore: true,
            hasMoreAfter: false,
            startCursor: JournalCursor(rawValue: "start"),
            endCursor: JournalCursor(rawValue: "end"),
            tailCursor: JournalCursor(rawValue: "end")
        )

        #expect(store.holes.isEmpty)
        #expect(store.unreadCount == 2)
        #expect(!store.unreadIsExact)
        #expect(!store.needsTailPull)

        store.markReadThrough(ReplicaTestSupport.seq(1_024))
        #expect(store.unreadCount == 1)
        #expect(store.unreadIsExact)

        store.apply(
            .entriesAppended(
                journalID: ReplicaTestSupport.journal,
                entries: [ReplicaTestSupport.entry(65_536)]
            ),
            origin: .live
        )
        #expect(store.entries.map(\.seq.rawValue) == [1_024, 8_192, 65_536])
        #expect(store.holes.isEmpty)
        #expect(store.unreadCount == 2)
        #expect(!store.needsTailPull)
    }

    @Test func cursorSegmentsRemainAlignedPastSixHundredRowsWhenPagingBackThenForward() {
        let store = ConversationReplica(
            sessionID: ReplicaTestSupport.session,
            journalID: ReplicaTestSupport.journal,
            windowCap: 600,
            clock: ReplicaTestSupport.clock()
        )

        func mergePage(_ lower: Int, _ upper: Int, retaining edge: ConversationPageRetentionEdge) {
            store.mergePage(
                journal: ReplicaTestSupport.journal,
                entries: (lower...upper).map { ReplicaTestSupport.entry($0) },
                windowStart: ReplicaTestSupport.seq(lower),
                windowEnd: ReplicaTestSupport.seq(upper),
                tailSeq: ReplicaTestSupport.seq(620),
                hasMoreBefore: lower > 1,
                hasMoreAfter: upper < 620,
                startCursor: JournalCursor(rawValue: "c\(lower - 1)"),
                endCursor: JournalCursor(rawValue: "c\(upper)"),
                tailCursor: JournalCursor(rawValue: "c620"),
                retaining: edge
            )
        }

        mergePage(601, 620, retaining: .newest)
        for upper in stride(from: 600, through: 20, by: -20) {
            mergePage(upper - 19, upper, retaining: .oldest)
        }

        #expect(store.entries.count == 600)
        #expect(store.entries.map(\.seq.rawValue) == Array(1...600))
        #expect(store.startCursor == JournalCursor(rawValue: "c0"))
        #expect(store.endCursor == JournalCursor(rawValue: "c600"))
        #expect(!store.hasMoreBefore)
        #expect(store.hasMoreAfter)
        #expect(Set(store.entries.map(\.seq)).count == store.entries.count)

        mergePage(601, 620, retaining: .newest)

        #expect(store.entries.count == 600)
        #expect(store.entries.map(\.seq.rawValue) == Array(21...620))
        #expect(store.startCursor == JournalCursor(rawValue: "c20"))
        #expect(store.endCursor == JournalCursor(rawValue: "c620"))
        #expect(store.hasMoreBefore)
        #expect(!store.hasMoreAfter)
        #expect(Set(store.entries.map(\.seq)).count == store.entries.count)
    }

    @Test func oversizedSingleCursorSegmentCannotExceedWindowCap() {
        let store = ConversationReplica(
            sessionID: ReplicaTestSupport.session,
            journalID: ReplicaTestSupport.journal,
            windowCap: 600,
            clock: ReplicaTestSupport.clock()
        )

        store.mergePage(
            journal: ReplicaTestSupport.journal,
            entries: (1...700).map { ReplicaTestSupport.entry($0) },
            windowStart: ReplicaTestSupport.seq(1),
            windowEnd: ReplicaTestSupport.seq(700),
            tailSeq: ReplicaTestSupport.seq(700),
            hasMoreBefore: false,
            hasMoreAfter: false,
            startCursor: JournalCursor(rawValue: "c0"),
            endCursor: JournalCursor(rawValue: "c700"),
            tailCursor: JournalCursor(rawValue: "c700"),
            retaining: .newest
        )

        #expect(store.entries.count == 600)
        #expect(store.entries.map(\.seq.rawValue) == Array(101...700))
    }
}
