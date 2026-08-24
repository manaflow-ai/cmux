import Testing

@testable import CmuxMobileChanges

@Suite struct DiffPagerPrefetchPolicyTests {
    private func files(_ paths: [String]) -> [ChangedFileItem] {
        paths.map { ChangedFileItem(path: $0, kind: .modified, additions: 1, deletions: 0, isBinary: false) }
    }

    @Test func warmsNearestFirstWithForwardBias() {
        let policy = DiffPagerPrefetchPolicy(radius: 2)

        let paths = policy.prefetchPaths(
            files: files(["a", "b", "c", "d", "e"]),
            selectedIndex: 2,
            cachedPaths: []
        )
        #expect(paths == ["d", "b", "e", "a"])
    }

    @Test func skipsAlreadyCachedPaths() {
        let policy = DiffPagerPrefetchPolicy(radius: 2)

        let paths = policy.prefetchPaths(
            files: files(["a", "b", "c", "d", "e"]),
            selectedIndex: 2,
            cachedPaths: ["d", "a"]
        )
        #expect(paths == ["b", "e"])
    }

    @Test func clipsAtSnapshotBounds() {
        let policy = DiffPagerPrefetchPolicy(radius: 2)

        #expect(policy.prefetchPaths(
            files: files(["a", "b", "c"]),
            selectedIndex: 0,
            cachedPaths: []
        ) == ["b", "c"])
        #expect(policy.prefetchPaths(
            files: files(["a", "b", "c"]),
            selectedIndex: 2,
            cachedPaths: []
        ) == ["b", "a"])
    }

    @Test func clampsAnOutOfRangeSelection() {
        let policy = DiffPagerPrefetchPolicy(radius: 1)

        #expect(policy.prefetchPaths(
            files: files(["a", "b"]),
            selectedIndex: 99,
            cachedPaths: []
        ) == ["a"])
        #expect(policy.prefetchPaths(
            files: files(["a", "b"]),
            selectedIndex: -3,
            cachedPaths: []
        ) == ["b"])
    }

    @Test func emptySnapshotWarmsNothing() {
        let policy = DiffPagerPrefetchPolicy()

        #expect(policy.prefetchPaths(files: [], selectedIndex: 0, cachedPaths: []).isEmpty)
    }

    @Test func defaultRadiusCoversTheNeighborPreloadWindow() {
        // UIPageViewController preloads the immediate neighbor of the
        // selected page; prefetch must reach at least one page beyond that
        // window so a newly preloaded page finds warm data.
        #expect(DiffPagerPrefetchPolicy().radius > 1)
    }
}
