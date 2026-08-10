import Foundation
@testable import CmuxTerminal

@MainActor
final class RecordingRestoreSpawnScheduler: TerminalSurfaceRuntimeSpawnScheduling {
    private(set) var scheduledSurfaceIds: [UUID] = []
    private var scheduledOperations: [@MainActor () -> Void] = []
    private let scheduledEvents = AsyncStream<UUID>.makeStream()

    func scheduleRestoredSurfaceSpawn(surfaceId: UUID, operation: @escaping @MainActor () -> Void) {
        scheduledSurfaceIds.append(surfaceId)
        scheduledOperations.append(operation)
        scheduledEvents.continuation.yield(surfaceId)
    }

    func runScheduledOperation(at index: Int = 0) {
        scheduledOperations[index]()
    }

    func waitForScheduledCount(_ count: Int) async {
        guard scheduledSurfaceIds.count < count else { return }
        for await _ in scheduledEvents.stream {
            guard scheduledSurfaceIds.count >= count else { continue }
            return
        }
    }
}
