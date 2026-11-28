import Testing

@testable import CmuxMobileShellUI

@Suite struct WorkspaceListRowHeightCacheTests {
    @Test func digitBucketsIgnoreExactCountsWithinTheSameLayoutWidth() {
        let first = WorkspaceChangesChipHeightKey(
            filesChanged: 12,
            additions: 34,
            deletions: 56,
            isInteractive: true
        )
        let second = WorkspaceChangesChipHeightKey(
            filesChanged: 98,
            additions: 76,
            deletions: 54,
            isInteractive: true
        )
        let wider = WorkspaceChangesChipHeightKey(
            filesChanged: 123,
            additions: 34,
            deletions: 56,
            isInteractive: true
        )

        #expect(first == second)
        #expect(first != wider)
    }

    @Test func supersededRowKeysDoNotAccumulateAndCacheRemainsBounded() {
        var cache = WorkspaceListRowHeightCache<Int>(maximumEntryCount: 3)
        cache.insert(44, for: 1, rowID: "row-a")
        cache.insert(45, for: 2, rowID: "row-a")

        #expect(cache.entryCount == 1)
        #expect(cache.height(for: 1) == nil)
        #expect(cache.height(for: 2) == 45)

        cache.insert(46, for: 3, rowID: "row-b")
        cache.insert(47, for: 4, rowID: "row-c")
        cache.insert(48, for: 5, rowID: "row-d")

        #expect(cache.entryCount == 3)
        #expect(cache.height(for: 2) == nil)
    }

    @Test func removedRowsReleaseTheirCacheOwnership() {
        var cache = WorkspaceListRowHeightCache<String>(maximumEntryCount: 3)
        cache.insert(44, for: "shared", rowID: "kept")
        cache.insert(44, for: "shared", rowID: "removed")

        cache.retainRowIDs(["kept"])
        cache.insert(45, for: "replacement", rowID: "removed")

        #expect(cache.entryCount == 2)
        #expect(cache.height(for: "shared") == 44)
        #expect(cache.height(for: "replacement") == 45)
    }
}
