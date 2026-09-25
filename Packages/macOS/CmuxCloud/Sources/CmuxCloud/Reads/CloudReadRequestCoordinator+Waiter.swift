import Foundation

extension CloudReadRequestCoordinator {
    public struct Waiter: Sendable {
        public let deadline: Duration
        public let continuation: CheckedContinuation<Response, Error>
    }
}
