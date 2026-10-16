import Foundation

extension CloudReadRequestCoordinator {
    public struct Waiter: Sendable {
        public let deadline: Duration
        public let continuation: CheckedContinuation<Response, Error>

        public init(
            deadline: Duration,
            continuation: CheckedContinuation<Response, Error>
        ) {
            self.deadline = deadline
            self.continuation = continuation
        }
    }
}
