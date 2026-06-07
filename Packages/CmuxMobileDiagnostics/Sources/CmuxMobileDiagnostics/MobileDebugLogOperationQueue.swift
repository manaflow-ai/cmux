import Foundation
import os

final class MobileDebugLogOperationQueue: Sendable {
    static let defaultPendingOperationLimit = 512

    private let sink: MobileDebugLogSink
    private let pendingAppendLimit: Int
    private let state = OSAllocatedUnfairLock(initialState: MobileDebugLogOperationQueueState())

    init(
        sink: MobileDebugLogSink,
        pendingOperationLimit: Int = MobileDebugLogOperationQueue.defaultPendingOperationLimit
    ) {
        self.sink = sink
        self.pendingAppendLimit = max(1, pendingOperationLimit)
    }

    func append(_ message: String) {
        enqueue(.append(message))
    }

    func clear() -> Task<Void, Never> {
        let receipt = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        enqueue(.clear(receipt.continuation))
        return Task {
            var iterator = receipt.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    private func enqueue(_ operation: MobileDebugLogOperation) {
        let shouldStartConsumer = state.withLock { state in
            switch operation {
            case .append:
                enqueueAppend(operation, state: &state)
            case .clear:
                state.pendingOperations.append(operation)
            }
            guard !state.isConsumerRunning else {
                return false
            }
            state.isConsumerRunning = true
            return true
        }
        if shouldStartConsumer {
            Task {
                await consume()
            }
        }
    }

    private func enqueueAppend(
        _ operation: MobileDebugLogOperation,
        state: inout MobileDebugLogOperationQueueState
    ) {
        if state.pendingAppendCount >= pendingAppendLimit,
           let dropIndex = state.pendingOperations.firstIndex(where: { pendingOperation in
               if case .append = pendingOperation {
                   return true
               }
               return false
           }) {
            state.pendingOperations.remove(at: dropIndex)
            state.pendingAppendCount -= 1
        }
        guard state.pendingAppendCount < pendingAppendLimit else {
            return
        }
        state.pendingOperations.append(operation)
        state.pendingAppendCount += 1
    }

    private func consume() async {
        while let operation = nextOperationOrStop() {
            await operation.run(on: sink)
        }
    }

    private func nextOperationOrStop() -> MobileDebugLogOperation? {
        state.withLock { state in
            guard !state.pendingOperations.isEmpty else {
                state.isConsumerRunning = false
                return nil
            }
            let operation = state.pendingOperations.removeFirst()
            if case .append = operation {
                state.pendingAppendCount -= 1
            }
            return operation
        }
    }
}

private struct MobileDebugLogOperationQueueState: Sendable {
    var pendingOperations: [MobileDebugLogOperation] = []
    var pendingAppendCount = 0
    var isConsumerRunning = false
}
