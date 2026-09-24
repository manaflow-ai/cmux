import Foundation

extension CloudReadRequestCoordinator {
    struct Waiter: Sendable {
        let deadline: Duration
        let continuation: CheckedContinuation<Response, Error>
    }
}
