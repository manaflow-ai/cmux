import Foundation

extension CmuxConfigActionCatalogReadCoordinator {
    struct ActiveRead {
        let id: UUID
        let requestID: UUID
        let lane: Lane
        let operation: @Sendable () async -> CmuxConfigActionCatalogSource?
        var isRunning: Bool
        var ownerTask: Task<Void, Never>?
        var waiters: [UUID: Waiter]
    }
}
