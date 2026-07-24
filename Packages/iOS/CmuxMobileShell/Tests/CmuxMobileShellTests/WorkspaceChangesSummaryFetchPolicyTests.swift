import Foundation
import Testing

@testable import CmuxMobileShell

@Suite struct WorkspaceChangesSummaryFetchPolicyTests {
    @Test func batchesAtSixtyFourWithoutDroppingIDs() {
        let policy = WorkspaceChangesSummaryFetchPolicy()
        let workspaceIDs = (0..<130).map { "workspace-\($0)" }

        let batches = policy.batches(
            workspaceIDs: workspaceIDs,
            fetchedAtByWorkspaceID: [:],
            now: Date(timeIntervalSince1970: 1_000),
            force: false
        )

        #expect(batches.map(\.count) == [64, 64, 2])
        #expect(batches.flatMap { $0 } == workspaceIDs)
        #expect(batches.allSatisfy { $0.count <= 64 })
    }

    @Test func skipsFreshIDsAndRefetchesAtReuseBoundary() {
        let policy = WorkspaceChangesSummaryFetchPolicy()
        let now = Date(timeIntervalSince1970: 1_000)
        let batches = policy.batches(
            workspaceIDs: ["fresh", "boundary", "stale", "new"],
            fetchedAtByWorkspaceID: [
                "fresh": now.addingTimeInterval(-14.999),
                "boundary": now.addingTimeInterval(-15),
                "stale": now.addingTimeInterval(-30),
            ],
            now: now,
            force: false
        )

        #expect(batches == [["boundary", "stale", "new"]])
    }

    @Test func forceBypassesReuseAndDeduplicatesInInputOrder() {
        let policy = WorkspaceChangesSummaryFetchPolicy(maximumBatchSize: 2)
        let now = Date(timeIntervalSince1970: 1_000)
        let batches = policy.batches(
            workspaceIDs: ["one", "one", "two", "", "three"],
            fetchedAtByWorkspaceID: [
                "one": now,
                "two": now,
                "three": now,
            ],
            now: now,
            force: true
        )

        #expect(batches == [["one", "two"], ["three"]])
    }

    @Test func freshEntriesArmOneTrailingFetchAtEarliestExpiry() {
        let policy = WorkspaceChangesSummaryFetchPolicy()
        let now = Date(timeIntervalSince1970: 1_000)

        let plan = policy.plan(
            workspaceIDs: ["later", "earliest", "earliest"],
            fetchedAtByWorkspaceID: [
                "later": now.addingTimeInterval(-2),
                "earliest": now.addingTimeInterval(-10),
            ],
            now: now,
            force: false
        )

        #expect(plan.batches.isEmpty)
        #expect(plan.freshUntilByWorkspaceID.count == 2)
        #expect(plan.earliestFreshExpiry == now.addingTimeInterval(5))
    }

    @Test func successfulFetchesArmEveryRequestedWorkspaceAtTheReuseBoundary() {
        let policy = WorkspaceChangesSummaryFetchPolicy(reuseWindow: 15)
        let fetchedAt = Date(timeIntervalSince1970: 1_000)

        let expiries = policy.freshUntilAfterSuccessfulFetch(
            workspaceIDs: ["workspace-a", "workspace-b", "workspace-a", ""],
            fetchedAt: fetchedAt
        )

        #expect(expiries == [
            "workspace-a": fetchedAt.addingTimeInterval(15),
            "workspace-b": fetchedAt.addingTimeInterval(15),
        ])
    }

    @Test func eachCompletedBatchReceivesItsOwnFreshReuseWindow() {
        let policy = WorkspaceChangesSummaryFetchPolicy(reuseWindow: 15)
        let firstCompletion = Date(timeIntervalSince1970: 1_010)
        let secondCompletion = Date(timeIntervalSince1970: 1_025)

        let firstExpiry = policy.freshUntilAfterSuccessfulFetch(
            workspaceIDs: ["workspace-a"],
            fetchedAt: firstCompletion
        )
        let secondExpiry = policy.freshUntilAfterSuccessfulFetch(
            workspaceIDs: ["workspace-b"],
            fetchedAt: secondCompletion
        )

        #expect(firstExpiry["workspace-a"] == firstCompletion.addingTimeInterval(15))
        #expect(secondExpiry["workspace-b"] == secondCompletion.addingTimeInterval(15))
    }

    @Test func trailingRefreshDelayHasAPositiveFiveSecondFloor() {
        let policy = WorkspaceChangesSummaryFetchPolicy(
            minimumTrailingRefreshDelay: 5
        )
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(policy.trailingRefreshDelay(
            deadline: now.addingTimeInterval(-20),
            now: now
        ) == 5)
        #expect(policy.trailingRefreshDelay(deadline: now, now: now) == 5)
        #expect(policy.trailingRefreshDelay(
            deadline: now.addingTimeInterval(12),
            now: now
        ) == 12)
    }

    @Test func foregroundWorkspaceSetPrunesBatchesMapsAndChips() {
        let workspaceSet = WorkspaceChangesSummaryWorkspaceSet(
            workspaceIDs: ["workspace-kept"]
        )
        let candidates = workspaceSet.workspaceIDs(
            retaining: ["workspace-removed", "workspace-kept"]
        )
        let fetchedAt = workspaceSet.values(retaining: [
            "workspace-removed": Date(timeIntervalSince1970: 1),
            "workspace-kept": Date(timeIntervalSince1970: 2),
        ])
        let chips = workspaceSet.values(retaining: [
            "workspace-removed": MobileWorkspaceChangesChip(
                filesChanged: 1,
                additions: 2,
                deletions: 3
            ),
            "workspace-kept": MobileWorkspaceChangesChip(
                filesChanged: 4,
                additions: 5,
                deletions: 6
            ),
        ])
        let batches = WorkspaceChangesSummaryFetchPolicy().batches(
            workspaceIDs: candidates,
            fetchedAtByWorkspaceID: [:],
            now: Date(timeIntervalSince1970: 3),
            force: false
        )

        #expect(batches == [["workspace-kept"]])
        #expect(Set(fetchedAt.keys) == ["workspace-kept"])
        #expect(Set(chips.keys) == ["workspace-kept"])
    }
}
