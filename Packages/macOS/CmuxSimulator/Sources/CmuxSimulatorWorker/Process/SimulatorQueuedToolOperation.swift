import Foundation

struct SimulatorQueuedToolOperation {
    let requestIdentifier: UUID
    let timeout: Duration
    let body: @MainActor @Sendable (SimulatorWorkerCoordinator, UUID) async -> Void
}
