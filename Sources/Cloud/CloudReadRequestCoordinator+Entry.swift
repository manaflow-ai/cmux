import Foundation

extension CloudReadRequestCoordinator {
    struct Entry: Sendable {
        let id: UUID
        let deadline: Duration
        var waiters: [UUID: Waiter]
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var terminalError: URLError?
        var invalidated = false
        let operation: @Sendable () async throws -> Response
        var pending: Pending?
    }
}
