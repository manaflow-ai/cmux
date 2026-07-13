import Foundation

/// Pure request planner for the host's 20-path Git-diff limit.
struct MobileDiffBatchPlanner: Sendable {
    private let maximumBatchSize = 20

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
