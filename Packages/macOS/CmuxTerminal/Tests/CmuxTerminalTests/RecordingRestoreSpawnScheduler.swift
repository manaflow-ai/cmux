import Foundation
@testable import CmuxTerminal

@MainActor
final class RecordingRestoreSpawnScheduler: TerminalSurfaceRuntimeSpawnScheduling {
    private(set) var scheduledSurfaceIds: [UUID] = []
    private(set) var scheduledResumesAgent: [Bool] = []
    private var scheduledOperations: [@MainActor () -> Void] = []
    private var scheduleCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func scheduleRestoredSurfaceSpawn(
        surfaceId: UUID,
        resumesAgent: Bool,
        operation: @escaping @MainActor () -> Void
    ) {
        scheduledSurfaceIds.append(surfaceId)
        scheduledResumesAgent.append(resumesAgent)
        scheduledOperations.append(operation)
        let ready = scheduleCountWaiters.filter { scheduledSurfaceIds.count >= $0.count }
        scheduleCountWaiters.removeAll { scheduledSurfaceIds.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func cancelRestoredSurfaceSpawn(surfaceId: UUID) {
        guard let index = scheduledSurfaceIds.firstIndex(of: surfaceId) else { return }
        scheduledSurfaceIds.remove(at: index)
        scheduledResumesAgent.remove(at: index)
        scheduledOperations.remove(at: index)
    }

    func runScheduledOperation(at index: Int = 0) {
        scheduledOperations[index]()
    }

    func waitForScheduledCount(_ count: Int) async {
        guard scheduledSurfaceIds.count < count else { return }
        await withCheckedContinuation { continuation in
            scheduleCountWaiters.append((count, continuation))
        }
    }
}
