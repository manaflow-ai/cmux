internal import Foundation

/// Cancellation token used to terminate a blocking process runner from a
/// coordinator-owned task.
///
/// `@unchecked Sendable` is safe because the lock protects the complete
/// mutable state, and handlers are always invoked after releasing the lock.
final class RemoteProcessCancellationOperation: RemoteTransferCancelling, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandler: (() -> Void)?

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
