#if canImport(UIKit)
import Synchronization
import os

/// Synchronous cancellation for libghostty work already enqueued off the main actor.
/// An actor hop here would delay the stale-read check behind the main actor.
final class SurfaceOperationCancellationToken: Sendable {
    private let state: any SurfaceOperationCancellationState

    init() {
        if #available(iOS 18.0, *) {
            state = MutexSurfaceOperationCancellationState()
        } else {
            state = LegacySurfaceOperationCancellationState()
        }
    }

    var isCancelled: Bool { state.isCancelled }

    func cancel() { state.cancel() }
}

private protocol SurfaceOperationCancellationState: Sendable {
    var isCancelled: Bool { get }
    func cancel()
}

@available(iOS 18.0, *)
private final class MutexSurfaceOperationCancellationState: SurfaceOperationCancellationState {
    // lint:allow lock - synchronous cross-queue cancellation for already-enqueued libghostty work.
    private let cancelled = Mutex(false)

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() { cancelled.withLock { $0 = true } }
}

private final class LegacySurfaceOperationCancellationState: SurfaceOperationCancellationState {
    // lint:allow lock - iOS 17 equivalent of the synchronous Mutex cancellation flag.
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() { cancelled.withLock { $0 = true } }
}
#endif
