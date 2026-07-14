import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileDiffBatchPlannerTests {
    @Test func chunksInOrderAtTwentyPaths() {
        let paths = (0..<43).map { request("file-\($0)") }
        let batches = MobileDiffBatchPlanner().initialBatches(paths: paths)

        #expect(batches.map(\.count) == [20, 20, 3])
        #expect(batches.flatMap { $0 } == paths)
    }

    @Test func emptyPathListProducesNoRequests() {
        #expect(MobileDiffBatchPlanner().initialBatches(paths: []).isEmpty)
    }

    @Test func retriesTruncatedRemainderAsOneOrderedBatch() {
        let planner = MobileDiffBatchPlanner()
        let retries = planner.truncatedRemainder(
            truncated: ["c", "unknown", "a", "c"],
            requestedOrder: [request("a"), request("b"), request("c"), request("d")]
        )

        #expect(retries == [request("a"), request("c")])
    }

    @Test func preservesRenameSourceAcrossInitialAndRetryBatches() {
        let renamed = MobileDiffRequestPath(path: "new.swift", oldPath: "old.swift")
        let planner = MobileDiffBatchPlanner()

        #expect(planner.initialBatches(paths: [renamed]) == [[renamed]])
        #expect(planner.truncatedRemainder(
            truncated: ["new.swift"],
            requestedOrder: [renamed]
        ) == [renamed])
        #expect(renamed.wireValue == [
            "path": "new.swift",
            "old_path": "old.swift",
        ])
    }

    private func request(_ path: String) -> MobileDiffRequestPath {
        MobileDiffRequestPath(path: path, oldPath: nil)
    }
}
