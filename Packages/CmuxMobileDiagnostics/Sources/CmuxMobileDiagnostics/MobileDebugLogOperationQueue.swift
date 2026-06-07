import Foundation

final class MobileDebugLogOperationQueue: Sendable {
    static let defaultPendingOperationLimit = 512

    private let mailbox: MobileDebugLogOperationMailbox

    init(
        sink: MobileDebugLogSink,
        pendingOperationLimit: Int = MobileDebugLogOperationQueue.defaultPendingOperationLimit
    ) {
        self.mailbox = MobileDebugLogOperationMailbox(
            sink: sink,
            pendingAppendLimit: pendingOperationLimit
        )
    }

    func append(_ message: String) {
        let mailbox = mailbox
        Task.detached {
            await mailbox.append(message)
        }
    }

    func clear() -> Task<Void, Never> {
        let mailbox = mailbox
        return Task.detached {
            await mailbox.clear()
        }
    }
}

private actor MobileDebugLogOperationMailbox {
    private let sink: MobileDebugLogSink
    private let pendingAppendLimit: Int
    private var pendingOperations: [MobileDebugLogOperation] = []
    private var pendingAppendCount = 0
    private var isConsumerRunning = false

    init(sink: MobileDebugLogSink, pendingAppendLimit: Int) {
        self.sink = sink
        self.pendingAppendLimit = max(1, pendingAppendLimit)
    }

    func append(_ message: String) {
        enqueue(.append(message))
    }

    func clear() async {
        let receipt = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        enqueue(.clear(receipt.continuation))
        var iterator = receipt.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    private func enqueue(_ operation: MobileDebugLogOperation) {
        switch operation {
        case .append:
            enqueueAppend(operation)
        case .clear:
            pendingOperations.append(operation)
        }
        startConsumerIfNeeded()
    }

    private func enqueueAppend(_ operation: MobileDebugLogOperation) {
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
        guard pendingAppendCount < pendingAppendLimit else {
            return
        }
        pendingOperations.append(operation)
        pendingAppendCount += 1
    }

    private func startConsumerIfNeeded() {
        guard !isConsumerRunning else { return }
        isConsumerRunning = true
        Task {
            await consume()
        }
    }

    private func consume() async {
        while let operation = dequeue() {
            await operation.run(on: sink)
        }
        finishConsuming()
    }

    private func dequeue() -> MobileDebugLogOperation? {
        guard !pendingOperations.isEmpty else {
            return nil
        }
        let operation = pendingOperations.removeFirst()
        if case .append = operation {
            pendingAppendCount -= 1
        }
        return operation
    }

    private func finishConsuming() {
        guard pendingOperations.isEmpty else {
            Task {
                await consume()
            }
            return
        }
        isConsumerRunning = false
    }
}
