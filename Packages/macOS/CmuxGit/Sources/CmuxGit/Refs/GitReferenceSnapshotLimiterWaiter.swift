import Foundation

/// One queued reference-snapshot permit waiter.
nonisolated struct GitReferenceSnapshotLimiterWaiter: Sendable {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
    let timeoutTask: Task<Void, Never>?
}
