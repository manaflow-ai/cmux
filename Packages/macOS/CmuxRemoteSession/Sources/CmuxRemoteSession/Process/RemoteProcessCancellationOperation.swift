internal import Foundation

/// Cancellation token used to terminate a blocking process runner from a
/// coordinator-owned task.
///
/// `installCancellationHandler` and `cancel` run synchronously from
/// non-isolated contexts that cannot await, so actor-backed state cannot serve
/// this bridge.
///
/// `@unchecked Sendable` is safe because the lock protects the complete
/// mutable state, and handlers are always invoked after releasing the lock.
final class RemoteProcessCancellationOperation: RemoteTransferCancelling, @unchecked Sendable {
    // lint:allow lock - Process termination handlers are synchronous and the
    // critical region only exchanges a cancellation bit and one callback.
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandler: (() -> Void)?

    deinit {}

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var cancellationError: any Error {
        CancellationError()
    }

    func throwIfCancelled() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    func installCancellationHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        let invokeImmediately = cancelled
        if !cancelled {
            cancellationHandler = handler
        }
        lock.unlock()

        if invokeImmediately {
            handler()
        }
    }

    func clearCancellationHandler() {
        lock.lock()
        cancellationHandler = nil
        lock.unlock()
    }

    func cancel() {
        let handler: (() -> Void)?
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        handler = cancellationHandler
        cancellationHandler = nil
        lock.unlock()

        handler?()
    }
}
