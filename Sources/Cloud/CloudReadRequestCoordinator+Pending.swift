import Foundation

extension CloudReadRequestCoordinator {
    struct Pending: Sendable {
        let id: UUID
        var waiters: [UUID: Waiter]
        let operation: @Sendable () async throws -> Response
        var timer: Task<Void, Never>?
    }
}
