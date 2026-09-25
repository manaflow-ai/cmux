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
    }
}
