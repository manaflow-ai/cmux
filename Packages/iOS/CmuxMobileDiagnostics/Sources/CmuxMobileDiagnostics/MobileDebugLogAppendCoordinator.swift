import Foundation

/// Bounded ordering gate for synchronous debug-log producers.
///
/// The sink remains the owner of log state. This gate only admits lines and
/// clear barriers in call order, then drains them through the sink actor so a
/// clear cannot overtake an earlier ``MobileDebugLog.append(_:)`` call.
// lint:allow lock - synchronous admission is required for nonisolated
// producers; the lock protects only a bounded in-memory queue.
final class MobileDebugLogAppendCoordinator: @unchecked Sendable {
    private enum Entry: Sendable {
        case line(String)
        case barrier(Acknowledgement)
    }

    private final class Acknowledgement: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func wait(timeoutNanoseconds: UInt64) async -> Bool {
            let timeoutTask = Task.detached { [self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    resolve(false)
                } catch {
                    // The waiter completed before the deadline.
                }
            }
            let result = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    lock.lock()
                    if let resolvedResult = self.result {
                        lock.unlock()
                        continuation.resume(returning: resolvedResult)
                    } else {
                        self.continuation = continuation
                        lock.unlock()
                    }
                }
            }, onCancel: {
                resolve(false)
            })
            timeoutTask.cancel()
            return result
        }

        func signal(_ result: Bool = true) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }

        private func resolve(_ result: Bool) {
            signal(result)
        }
    }

    /// Shared drain state lives outside the coordinator so the detached drain
    /// task cannot retain the coordinator while it waits for new entries.
    private final class Storage: @unchecked Sendable {
        private struct State: Sendable {
            var entries: [Entry] = []
            var finished = false
        }

        private let lock = NSLock()
        private var state = State()
        private let maxBufferedEntries: Int
        private let wakeContinuation: AsyncStream<Void>.Continuation
        private var wakeIterator: AsyncStream<Void>.Iterator

        init(maxBufferedEntries: Int) {
            self.maxBufferedEntries = max(1, maxBufferedEntries)
            let (stream, continuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            wakeContinuation = continuation
            wakeIterator = stream.makeAsyncIterator()
        }

        func finish() -> [Entry] {
            let pending = withStateLock { state in
                state.finished = true
                let pending = state.entries
                state.entries.removeAll(keepingCapacity: false)
                return pending
            }
            wakeContinuation.finish()
            return pending
        }

        func enqueue(_ message: String) {
            withStateLock { state in
                guard !state.finished else { return }
                if state.entries.count >= maxBufferedEntries,
                   let oldestLine = state.entries.firstIndex(where: { entry in
                       if case .line = entry { return true }
                       return false
                   }) {
                    state.entries.remove(at: oldestLine)
                }
                state.entries.append(.line(message))
            }
            wakeContinuation.yield(())
        }

        func admit(_ acknowledgement: Acknowledgement) -> Bool {
            let admitted = withStateLock { state in
                guard !state.finished else { return false }
                if state.entries.count >= maxBufferedEntries {
                    guard let oldestLine = state.entries.firstIndex(where: { entry in
                        if case .line = entry { return true }
                        return false
                    }) else {
                        return false
                    }
                    state.entries.remove(at: oldestLine)
                }
                state.entries.append(.barrier(acknowledgement))
                return true
            }
            if admitted {
                wakeContinuation.yield(())
            }
            return admitted
        }

        func nextBatch() async -> [Entry]? {
            while true {
                let batch = withStateLock { state -> [Entry]? in
                    guard !state.entries.isEmpty else {
                        return state.finished ? nil : []
                    }
                    let batch = state.entries
                    state.entries.removeAll(keepingCapacity: true)
                    return batch
                }
                if let batch, !batch.isEmpty { return batch }
                if batch == nil { return nil }
                guard await wakeIterator.next() != nil else {
                    return withStateLock { state in
                        guard !state.entries.isEmpty else { return nil }
                        let batch = state.entries
                        state.entries.removeAll(keepingCapacity: true)
                        return batch
                    }
                }
            }
        }

        private func withStateLock<T>(_ body: (inout State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&state)
        }
    }

    private let storage: Storage
    private static let drainWaitTimeoutNanoseconds: UInt64 = 5_000_000_000

    init(sink: MobileDebugLogSink, maxBufferedEntries: Int = 2_048) {
        let storage = Storage(maxBufferedEntries: maxBufferedEntries)
        self.storage = storage
        Task.detached { [storage, sink] in
            await Self.drain(storage: storage, sink: sink)
        }
    }

    deinit {
        let pending = storage.finish()
        for entry in pending {
            if case .barrier(let acknowledgement) = entry {
                acknowledgement.signal(false)
            }
        }
    }

    func enqueue(_ message: String) {
        storage.enqueue(message)
    }

    func flush() async -> Bool {
        let acknowledgement = Acknowledgement()
        let admitted = storage.admit(acknowledgement)
        guard admitted else { return false }
        return await acknowledgement.wait(
            timeoutNanoseconds: Self.drainWaitTimeoutNanoseconds
        )
    }

    private static func drain(storage: Storage, sink: MobileDebugLogSink) async {
        while let batch = await storage.nextBatch() {
            for entry in batch {
                switch entry {
                case .line(let message):
                    await sink.append(message)
                case .barrier(let acknowledgement):
                    acknowledgement.signal()
                }
            }
        }
    }
}
