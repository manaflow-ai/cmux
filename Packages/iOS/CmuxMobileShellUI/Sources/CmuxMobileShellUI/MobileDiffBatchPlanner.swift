import Foundation

/// Pure request planner for the host's 20-path Git-diff limit.
struct MobileDiffBatchPlanner: Sendable {
    private let maximumBatchSize = 20

    func initialBatches(paths: [MobileDiffRequestPath]) -> [[MobileDiffRequestPath]] {
        stride(from: 0, to: paths.count, by: maximumBatchSize).map { offset in
            Array(paths[offset..<min(offset + maximumBatchSize, paths.count)])
        }
    }

    /// Preserves the truncated remainder as one ordered follow-up request.
    func truncatedRemainder(
        truncated: [String],
        requestedOrder: [MobileDiffRequestPath]
    ) -> [MobileDiffRequestPath] {
        let truncatedSet = Set(truncated)
        var seen: Set<String> = []
        return requestedOrder.compactMap { path in
            guard truncatedSet.contains(path.path), seen.insert(path.path).inserted else { return nil }
            return path
        }
    }
}
