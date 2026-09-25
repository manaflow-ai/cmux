import Foundation

extension CloudReadRequestCoordinator {
    public struct Pending: Sendable {
        public let id: UUID
        public var waiters: [UUID: Waiter]
        public let operation: @Sendable () async throws -> Response
        public var timer: Task<Void, Never>?
    }
}
