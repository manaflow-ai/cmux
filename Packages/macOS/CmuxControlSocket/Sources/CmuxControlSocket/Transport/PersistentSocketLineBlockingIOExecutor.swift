internal import Dispatch
internal import Foundation

/// Bounded lanes for socket calls that can block in the kernel.
///
/// Every connection owns one serial lane, preserving request order without
/// occupying Swift's cooperative executor while a peer is stalled.
final class PersistentSocketLineBlockingIOExecutor: @unchecked Sendable {
    static let shared = PersistentSocketLineBlockingIOExecutor()

    private let lanes: [DispatchQueue]
    private let lock = NSLock()
    private var nextLaneIndex = 0

    init(
        laneCount: Int = min(
            max(ProcessInfo.processInfo.activeProcessorCount, 4),
            64
        )
    ) {
        precondition(laneCount > 0)
        lanes = (0..<laneCount).map { index in
            DispatchQueue(
                label: "com.cmux.control-socket.blocking-io.\(index)",
                qos: .userInitiated
            )
        }
    }

    func makeLane() -> DispatchQueue {
        lock.withLock {
            let lane = lanes[nextLaneIndex]
            nextLaneIndex = (nextLaneIndex + 1) % lanes.count
            return lane
        }
    }
}
