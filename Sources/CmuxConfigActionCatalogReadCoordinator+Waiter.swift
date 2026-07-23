import Foundation

extension CmuxConfigActionCatalogReadCoordinator {
    struct Waiter {
        let requestID: UUID
        let continuation: CheckedContinuation<WaitResult, Never>
    }
}
