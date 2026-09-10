import Foundation

/// One queued reference-snapshot permit waiter.
struct GitReferenceSnapshotLimiterWaiter: Sendable {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
    let timeoutTask: Task<Void, Never>?
}
