import Foundation

/// A single-consumer async message queue bounded by aggregate payload bytes.
///
/// Web Inspector publishes its initial application census as a burst. A
/// one-element `AsyncStream` drops valid protocol messages before its consumer
/// can run, while a count-based queue can retain several maximum-sized frames.
/// This queue preserves every message that fits under one explicit byte ceiling.
struct SimulatorWebInspectorMessageStream: AsyncSequence, Sendable {
    typealias Element = Data

    enum YieldResult {
        case enqueued
        case overflow
        case terminated
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let storage: Storage

        mutating func next() async -> Data? {
            await storage.next()
        }
    }

    private let storage: Storage

    init(maximumBufferedBytes: Int) {
        storage = Storage(maximumBufferedBytes: maximumBufferedBytes)
    }

    static func finished() -> Self {
        let stream = Self(maximumBufferedBytes: 0)
        stream.finish()
        return stream
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage)
    }

    func yield(_ data: Data) -> YieldResult {
        storage.yield(data)
    }

    func finish() {
        storage.finish()
    }

    fileprivate final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBufferedBytes: Int
        private var bufferedMessages: [Data] = []
        private var bufferedHead = 0
        private var bufferedBytes = 0
        private var waiter: CheckedContinuation<Data?, Never>?
        private var isFinished = false

        init(maximumBufferedBytes: Int) {
            self.maximumBufferedBytes = Swift.max(0, maximumBufferedBytes)
        }

        func next() async -> Data? {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                lock.lock()
                if bufferedHead < bufferedMessages.count {
                    let message = bufferedMessages[bufferedHead]
                    bufferedHead += 1
                    bufferedBytes -= message.count
                    compactBufferIfNeeded()
                    lock.unlock()
                    continuation.resume(returning: message)
                    return
                }
                if isFinished {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                precondition(waiter == nil, "Web Inspector message stream has multiple consumers")
                waiter = continuation
                lock.unlock()
            }
        }

        func yield(_ data: Data) -> YieldResult {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return .terminated
            }
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: data)
                return .enqueued
            }
            guard data.count <= maximumBufferedBytes - bufferedBytes else {
                isFinished = true
                lock.unlock()
                return .overflow
            }
            bufferedMessages.append(data)
            bufferedBytes += data.count
            lock.unlock()
            return .enqueued
        }

        func finish() {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            let waiter = waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: nil)
        }

        private func compactBufferIfNeeded() {
            guard bufferedHead > 64, bufferedHead * 2 >= bufferedMessages.count else {
                return
            }
            bufferedMessages.removeFirst(bufferedHead)
            bufferedHead = 0
        }
    }
}
