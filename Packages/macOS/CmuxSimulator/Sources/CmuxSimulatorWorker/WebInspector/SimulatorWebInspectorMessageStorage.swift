import Foundation

actor SimulatorWebInspectorMessageStorage {
    private let maximumBufferedBytes: Int
    private let maximumBufferedMessages: Int
    private var bufferedMessages: [Data] = []
    private var bufferedHead = 0
    private var bufferedBytes = 0
    private var waiter: (
        id: UUID,
        continuation: CheckedContinuation<Data?, Never>
    )?
    private var isFinished: Bool

    init(
        maximumBufferedBytes: Int,
        maximumBufferedMessages: Int,
        initiallyFinished: Bool
    ) {
        self.maximumBufferedBytes = Swift.max(0, maximumBufferedBytes)
        self.maximumBufferedMessages = Swift.max(0, maximumBufferedMessages)
        isFinished = initiallyFinished
    }

    func next() async -> Data? {
        guard !Task.isCancelled else { return nil }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if bufferedHead < bufferedMessages.count {
                    continuation.resume(returning: removeFirstBufferedMessage())
                } else if isFinished {
                    continuation.resume(returning: nil)
                } else {
                    precondition(
                        waiter == nil,
                        "Web Inspector message stream has multiple consumers"
                    )
                    waiter = (waiterID, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    func yield(_ data: Data) -> SimulatorWebInspectorMessageYieldResult {
        guard !isFinished else { return .terminated }
        guard !data.isEmpty else { return terminateForOverflow() }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: data)
            return .enqueued
        }
        guard bufferedMessages.count - bufferedHead < maximumBufferedMessages,
              data.count <= maximumBufferedBytes - bufferedBytes else {
            return terminateForOverflow()
        }
        bufferedMessages.append(data)
        bufferedBytes += data.count
        return .enqueued
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let waiter = waiter
        self.waiter = nil
        waiter?.continuation.resume(returning: nil)
    }

    var retainedBufferedBytes: Int {
        bufferedMessages.reduce(into: 0) { $0 += $1.count }
    }

    private func cancelWaiter(id: UUID) {
        guard waiter?.id == id else { return }
        let waiter = waiter
        self.waiter = nil
        waiter?.continuation.resume(returning: nil)
    }

    private func terminateForOverflow() -> SimulatorWebInspectorMessageYieldResult {
        isFinished = true
        let waiter = waiter
        self.waiter = nil
        waiter?.continuation.resume(returning: nil)
        return .overflow
    }

    private func removeFirstBufferedMessage() -> Data {
        let message = bufferedMessages[bufferedHead]
        bufferedMessages[bufferedHead] = Data()
        bufferedHead += 1
        bufferedBytes -= message.count
        if bufferedHead == bufferedMessages.count {
            bufferedMessages.removeAll(keepingCapacity: false)
            bufferedHead = 0
        } else {
            compactBufferIfNeeded()
        }
        return message
    }

    private func compactBufferIfNeeded() {
        guard bufferedHead > 64, bufferedHead * 2 >= bufferedMessages.count else {
            return
        }
        bufferedMessages.removeFirst(bufferedHead)
        bufferedHead = 0
    }
}
