internal import Foundation

struct BackendOnlyRendererOperationWaiter {
    let identifier: UUID
    let continuation: CheckedContinuation<Bool, Never>
}
