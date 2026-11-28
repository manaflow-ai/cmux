import Foundation

extension CloudReadRequestCoordinator {
    public struct Pending: Sendable {
        public let id: UUID
        public var waiters: [UUID: Waiter]
        public let operation: @Sendable () async throws -> Response
        public var timer: Task<Void, Never>?

        public init(
            id: UUID,
            waiters: [UUID: Waiter],
            operation: @escaping @Sendable () async throws -> Response,
            timer: Task<Void, Never>? = nil
        ) {
            self.id = id
            self.waiters = waiters
            self.operation = operation
            self.timer = timer
        }
    }
}
