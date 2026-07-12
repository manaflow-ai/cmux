@testable import CmuxAgentGUIUI
import Testing
import CmuxAgentGUIProjection
import CmuxAgentReplica

@Suite
struct TranscriptInteractionPolicyTests {
    @Test
    func rowSpacingResolvesTheExactAdjacentKindToken() {
        let journal = JournalID(rawValue: "journal")
        let rows = [
            TranscriptRow(
                rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: 3)),
                rowKind: .proseAgent(text: "newer", grouping: .last)
            ),
            TranscriptRow(
                rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: 2)),
                rowKind: .proseAgent(text: "older", grouping: .first)
            ),
            TranscriptRow(
                rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: 1)),
                rowKind: .genericActivity(TranscriptGenericActivity(kindLabel: "tool", summary: "done"))
            ),
        ]
        let spacing = TranscriptRowSpacing.resolved(for: rows)

        let intra = spacing[rows[0].rowID]!.top + spacing[rows[1].rowID]!.bottom
        let activity = spacing[rows[1].rowID]!.top + spacing[rows[2].rowID]!.bottom

        #expect(abs(intra - TranscriptRowSpacing.intraGroup) < 0.001)
        #expect(abs(activity - TranscriptRowSpacing.activity) < 0.001)
    }

    @Test
    func unreadCountTracksRowsNewerThanNewestSeenViewportRow() {
        let journal = JournalID(rawValue: "journal")
        let rows = (1...6).reversed().map { seq in
            TranscriptRow(
                rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: seq)),
                rowKind: .streaming(textTail: "\(seq)"),
                isUnread: true
            )
        }
        var tracker = TranscriptUnreadTracker()

        let initial = tracker.unreadCount(rows: rows, visibleRowIDs: [rows[4].rowID, rows[5].rowID])
        let advanced = tracker.unreadCount(rows: rows, visibleRowIDs: [rows[2].rowID, rows[3].rowID])
        let scrolledBack = tracker.unreadCount(rows: rows, visibleRowIDs: [rows[4].rowID, rows[5].rowID])
        let reachedNewest = tracker.unreadCount(rows: rows, visibleRowIDs: [rows[0].rowID, rows[1].rowID])

        #expect(initial == 4)
        #expect(advanced == 2)
        #expect(scrolledBack == 2)
        #expect(reachedNewest == 0)
    }

    @Test
    func unreadCountIncludesEveryLaterBurstBeforeTheSeenBoundary() {
        let journal = JournalID(rawValue: "journal")
        func rows(_ range: ClosedRange<Int>) -> [TranscriptRow] {
            range.reversed().map { seq in
                TranscriptRow(
                    rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: seq)),
                    rowKind: .streaming(textTail: "\(seq)"),
                    isUnread: true
                )
            }
        }
        var tracker = TranscriptUnreadTracker()
        let first = rows(1...6)
        let afterSecondBurst = rows(1...8)

        #expect(tracker.unreadCount(rows: first, visibleRowIDs: [first[4].rowID]) == 4)
        #expect(tracker.unreadCount(rows: afterSecondBurst, visibleRowIDs: [first[4].rowID]) == 6)
    }

    @Test
    func activeScrollNewestInsertPreservesAnchorWhenAwayFromBottom() {
        let policy = TranscriptMutationApplyPolicy(
            scrollIsInteracting: true,
            distanceFromBottom: 120,
            insertedIndexes: [0]
        )

        #expect(policy.mode == .nonAnimatedPreservingAnchor)
    }

    @Test
    func activeScrollAnyInsertPreservesAnchorWhenAwayFromBottom() {
        let policy = TranscriptMutationApplyPolicy(
            scrollIsInteracting: true,
            distanceFromBottom: 120,
            insertedIndexes: [240, 241]
        )

        #expect(policy.mode == .nonAnimatedPreservingAnchor)
    }

    @Test
    func idleAtBottomIsOnlyAnimatedMode() {
        let idleAtBottom = TranscriptMutationApplyPolicy(
            scrollIsInteracting: false,
            distanceFromBottom: 0,
            insertedIndexes: [0]
        )
        let idleAwayFromBottom = TranscriptMutationApplyPolicy(
            scrollIsInteracting: false,
            distanceFromBottom: 80,
            insertedIndexes: [0]
        )

        #expect(idleAtBottom.mode == .animatedIdleAtBottom)
        #expect(idleAwayFromBottom.mode == .nonAnimatedPreservingAnchor)
    }

}
