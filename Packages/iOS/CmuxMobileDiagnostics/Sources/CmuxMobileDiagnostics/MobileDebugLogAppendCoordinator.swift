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
        case batch([String])
        case barrier(Acknowledgement)
    }

    private final class Acknowledgement: @unchecked Sendable {
        // lint:allow lock - synchronous acknowledgement resolution is required
        // for cancellation and timeout races across producer tasks.
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

        // lint:allow lock - synchronous admission is required for nonisolated
        // producers; the lock protects only a bounded in-memory queue.
        private let lock = NSLock()
        private var state = State()
        private let maxBufferedEntries: Int
        private let maxBufferedControlEntries: Int
        private let wakeContinuation: AsyncStream<Void>.Continuation
        private var wakeIterator: AsyncStream<Void>.Iterator

        init(maxBufferedEntries: Int) {
            self.maxBufferedEntries = max(1, maxBufferedEntries)
            self.maxBufferedControlEntries = 16
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
            enqueue(.line(message))
        }

        func enqueueBatch(_ messages: [String]) {
            guard !messages.isEmpty else { return }
            enqueue(.batch(messages))
        }

        private func enqueue(_ entry: Entry) {
            withStateLock { state in
                guard !state.finished else { return }
                if Self.isDroppable(entry), state.entries.count >= maxBufferedEntries {
                    // The synchronous hot path drops the incoming line in
                    // constant time. Control admission below may still evict
                    // an older droppable entry to preserve ordering barriers.
                    return
                }
                if state.entries.count >= maxBufferedEntries {
                    guard let oldestDroppable = state.entries.firstIndex(where: Self.isDroppable) else {
                        return
                    }
                    state.entries.remove(at: oldestDroppable)
                }
                state.entries.append(entry)
            }
            wakeContinuation.yield(())
        }

        func admit(_ acknowledgement: Acknowledgement) -> Bool {
            let admitted = withStateLock { state in
                guard !state.finished else { return false }
                if state.entries.count >= maxBufferedEntries + maxBufferedControlEntries {
                    // A barrier must not displace a line that was already
                    // accepted. The reserved control lane is bounded;
                    // exhaustion fails closed rather than losing traffic.
                    return false
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

        private static func isDroppable(_ entry: Entry) -> Bool {
            switch entry {
            case .line, .batch:
                return true
            case .barrier:
                return false
            }
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

    func enqueueBatch(_ messages: [String]) {
        storage.enqueueBatch(messages)
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
                await drain(entry, to: sink)
            }
        }
    }

    private static func drain(_ entry: Entry, to sink: MobileDebugLogSink) async {
        switch entry {
        case .line(let message):
            await sink.append(message)
        case .batch(let messages):
            await sink.appendBatch(messages)
        case .barrier(let acknowledgement):
            acknowledgement.signal()
        }
    }
}
