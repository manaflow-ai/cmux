import Foundation

extension CloudReadRequestCoordinator {
    public struct Entry: Sendable {
        public let id: UUID
        /// Fixed at transport admission; later callers and retries never renew it.
        let transportDeadline: Duration
        public var waiters: [UUID: Waiter]
        public var work: Task<Void, Never>?
        public var timer: Task<Void, Never>?
        public var terminalError: URLError?
        public var invalidated = false
        public let operation: @Sendable () async throws -> Response
        public var pending: Pending?

        public init(
            id: UUID,
            transportDeadline: Duration,
            waiters: [UUID: Waiter],
            work: Task<Void, Never>? = nil,
            timer: Task<Void, Never>? = nil,
            terminalError: URLError? = nil,
            invalidated: Bool = false,
            operation: @escaping @Sendable () async throws -> Response,
            pending: Pending? = nil
        ) {
            self.id = id
            self.transportDeadline = transportDeadline
            self.waiters = waiters
            self.work = work
            self.timer = timer
            self.terminalError = terminalError
            self.invalidated = invalidated
            self.operation = operation
            self.pending = pending
        }
    }
}
