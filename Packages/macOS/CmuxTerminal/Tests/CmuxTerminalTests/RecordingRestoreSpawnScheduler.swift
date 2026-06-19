import Foundation
@testable import CmuxTerminal

@MainActor
final class RecordingRestoreSpawnScheduler: TerminalSurfaceRuntimeSpawnScheduling {
    private(set) var scheduledSurfaceIds: [UUID] = []
    private var scheduledOperations: [@MainActor () -> Void] = []

    func scheduleRestoredSurfaceSpawn(surfaceId: UUID, operation: @escaping @MainActor () -> Void) {
        scheduledSurfaceIds.append(surfaceId)
        scheduledOperations.append(operation)
    }

    func runScheduledOperation(at index: Int = 0) {
        scheduledOperations[index]()
    }
}
