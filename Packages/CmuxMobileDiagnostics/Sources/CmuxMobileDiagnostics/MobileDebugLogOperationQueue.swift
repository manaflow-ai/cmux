import Foundation

final class MobileDebugLogOperationQueue: @unchecked Sendable {
    static let defaultPendingOperationLimit = 512

    private let sink: MobileDebugLogSink
    private let pendingAppendLimit: Int
    // lint:allow lock — small synchronous bridge used so render/IO callers can
    // enqueue diagnostics without awaiting the actor; the lock only protects the
    // in-memory FIFO and waiter, while sink mutation remains actor-isolated.
    private let lock = NSLock()
    private var pendingOperations: [MobileDebugLogOperation] = []
    private var pendingAppendCount = 0
    private var waiter: CheckedContinuation<Void, Never>?

    init(
        sink: MobileDebugLogSink,
        pendingOperationLimit: Int = MobileDebugLogOperationQueue.defaultPendingOperationLimit
    ) {
        self.sink = sink
        self.pendingAppendLimit = max(1, pendingOperationLimit)
        Task.detached {
            while true {
                let operation = await self.nextOperation()
                await operation.run(on: sink)
            }
        }
    }

    func append(_ message: String) {
        yield(.append(message))
    }

    func clear() -> Task<Void, Never> {
        let receipt = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        enqueueClear(.clear(receipt.continuation))
        return Task.detached {
            var iterator = receipt.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    private func yield(_ operation: MobileDebugLogOperation) {
        switch operation {
        case .append:
            enqueueAppend(operation)
        case .clear:
            enqueueClear(operation)
        }
    }

    private func enqueueAppend(_ operation: MobileDebugLogOperation) {
        var waiterToResume: CheckedContinuation<Void, Never>?
        lock.lock()
        if pendingAppendCount >= pendingAppendLimit,
           let dropIndex = pendingOperations.firstIndex(where: { pendingOperation in
               if case .append = pendingOperation {
                   return true
               }
               return false
           }) {
            pendingOperations.remove(at: dropIndex)
            pendingAppendCount -= 1
        }
        if pendingAppendCount < pendingAppendLimit {
            pendingOperations.append(operation)
            pendingAppendCount += 1
            waiterToResume = waiter
            waiter = nil
        }
        lock.unlock()
        waiterToResume?.resume()
    }

    private func enqueueClear(_ operation: MobileDebugLogOperation) {
        var waiterToResume: CheckedContinuation<Void, Never>?
        lock.lock()
        pendingOperations.append(operation)
        waiterToResume = waiter
        waiter = nil
        lock.unlock()
        waiterToResume?.resume()
    }

    private func nextOperation() async -> MobileDebugLogOperation {
        while true {
            if let operation = popOperation() {
                return operation
            }
            await waitForOperation()
        }
    }

    private func popOperation() -> MobileDebugLogOperation? {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingOperations.isEmpty else {
            return nil
        }
        let operation = pendingOperations.removeFirst()
        if case .append = operation {
            pendingAppendCount -= 1
        }
        return operation
    }

    private func waitForOperation() async {
        await withCheckedContinuation { continuation in
            var shouldResumeImmediately = false
            lock.lock()
            if pendingOperations.isEmpty {
                waiter = continuation
            } else {
                shouldResumeImmediately = true
            }
            lock.unlock()
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }
}
