@testable import CmuxAgentGUIUI
import Testing
import CmuxAgentGUIProjection
import CmuxAgentReplica

@Suite
struct TranscriptInteractionPolicyTests {
    @Test(arguments: TranscriptDensity.allCases)
    func rowSpacingResolvesTheExactAdjacentKindToken(density: TranscriptDensity) {
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
        let spacing = TranscriptRowSpacing.resolved(for: rows, density: density)
        let register = TranscriptRowSpacing.register(for: density)

        let intra = spacing[rows[0].rowID]!.top + spacing[rows[1].rowID]!.bottom
        let activity = spacing[rows[1].rowID]!.top + spacing[rows[2].rowID]!.bottom

        #expect(abs(intra - register.intraGroup) < 0.001)
        #expect(abs(activity - register.activity) < 0.001)
        #expect(spacing.values.allSatisfy { $0.density == density })
    }

    @Test(arguments: TranscriptDensity.allCases)
    func rowSpacingRegistersAreTokenExactAndOrdered(density: TranscriptDensity) {
        let register = TranscriptRowSpacing.register(for: density)
        switch density {
        case .comfortable:
            #expect(register.intraGroup == 4)
            #expect(register.activity == 8)
            #expect(register.interGroup == 12)
            #expect(register.turnBottom == 16)
            #expect(register.activityItem == 1)
            #expect(register.metadataVerticalPadding == 4)
            #expect(register.activityVerticalPadding == 4)
            #expect(register.activityItemHeight == 24)
            #expect(register.activitySummaryLabelHeight == 26)
            #expect(register.activitySummaryMinimumHeight == 44)
        case .compact:
            #expect(register.intraGroup == 2)
            #expect(register.activity == 5)
            #expect(register.interGroup == 8)
            #expect(register.turnBottom == 10)
            #expect(register.activityItem == 1)
            #expect(register.metadataVerticalPadding == 1)
            #expect(register.activityVerticalPadding == 1)
            #expect(register.activityItemHeight == 18)
            #expect(register.activitySummaryLabelHeight == 20)
            #expect(register.activitySummaryMinimumHeight == 32)
        }
        #expect(register.intraGroup < register.activity)
        #expect(register.activity < register.interGroup)
        #expect(register.interGroup < register.turnBottom)
    }

    @Test
    func rowSpacingResolutionHasNoDensityOrderDependence() {
        let journal = JournalID(rawValue: "density-purity")
        let rows = [
            TranscriptRow(
                rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: 3)),
                rowKind: .proseUser(text: "Prompt", ticketState: nil, grouping: .single)
            ),
            TranscriptRow(
                rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: 2)),
                rowKind: .activityItem(TranscriptActivityItem(
                    id: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: 2)),
                    kind: .tool,
                    summary: "Running",
                    isRunning: true
                ))
            ),
            TranscriptRow(
                rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: 1)),
                rowKind: .genericActivity(TranscriptGenericActivity(
                    kindLabel: "future_kind",
                    summary: "Unknown"
                ))
            ),
        ]

        let comfortableBefore = TranscriptRowSpacing.resolved(for: rows, density: .comfortable)
        let compactBefore = TranscriptRowSpacing.resolved(for: rows, density: .compact)
        let comfortableAfter = TranscriptRowSpacing.resolved(for: rows, density: .comfortable)
        let compactAfter = TranscriptRowSpacing.resolved(for: rows, density: .compact)

        #expect(comfortableAfter == comfortableBefore)
        #expect(compactAfter == compactBefore)
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
