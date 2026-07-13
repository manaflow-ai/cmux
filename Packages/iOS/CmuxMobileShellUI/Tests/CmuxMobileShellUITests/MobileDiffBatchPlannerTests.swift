import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileDiffBatchPlannerTests {
    @Test func chunksInOrderAtTwentyPaths() {
        let paths = (0..<43).map { "file-\($0)" }
        let batches = MobileDiffBatchPlanner().initialBatches(paths: paths)

        #expect(batches.map(\.count) == [20, 20, 3])
        #expect(batches.flatMap { $0 } == paths)
    }

    @Test func retriesTruncatedPathsIndividuallyInRequestedOrder() {
        let planner = MobileDiffBatchPlanner()
        let retries = planner.truncatedRetryBatches(
            truncated: ["c", "a", "c"],
            requestedOrder: ["a", "b", "c", "d"]
        )

        #expect(retries == [["a"], ["c"]])
    }
}
