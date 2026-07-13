import Foundation

/// Pure request planner for the host's 20-path Git-diff limit.
struct MobileDiffBatchPlanner: Sendable {
    let maximumBatchSize: Int

    init(maximumBatchSize: Int = 20) {
        precondition(maximumBatchSize > 0)
        self.maximumBatchSize = maximumBatchSize
    }

    func initialBatches(paths: [String]) -> [[String]] {
        stride(from: 0, to: paths.count, by: maximumBatchSize).map { offset in
            Array(paths[offset..<min(offset + maximumBatchSize, paths.count)])
        }
    }

    /// Plans one-path follow-up calls in original status order, without duplicates.
    func truncatedRetryBatches(truncated: [String], requestedOrder: [String]) -> [[String]] {
        let truncatedSet = Set(truncated)
        var seen: Set<String> = []
        return requestedOrder.compactMap { path in
            guard truncatedSet.contains(path), seen.insert(path).inserted else { return nil }
            return [path]
        }
    }
}
