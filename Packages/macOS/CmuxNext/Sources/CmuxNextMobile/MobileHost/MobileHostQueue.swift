import CmuxNextCompat
import Foundation

/// One producer and one consumer. A full queue slows the producer instead of
/// dropping a request. The pipe callback uses `push`; the actor uses `send`.
final class MobileHostQueue<Element: Sendable>: Sendable {
    private struct State {
        var items: [Element] = []
        var reader: CheckedContinuation<Element?, Never>?
        var writer: (Element, CheckedContinuation<Void, Never>)?
        var ended = false
    }

    private let state = Mutex(State())
    private let condition = NSCondition()
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    var stream: AsyncStream<Element> {
        AsyncStream(unfolding: { await self.next() }, onCancel: { self.cancel() })
    }

    /// Foundation's pipe queue only. Leaving bytes in the OS pipe backpressures hostd.
    func push(_ item: Element) {
        condition.lock()
        while state.withLock({ !$0.ended && $0.items.count == capacity }) {
            // concurrency-allow: only the Foundation pipe callback waits; the async consumer and cancellation wake it.
            condition.blockingWait()
        }
        let reader = state.withLock { state -> CheckedContinuation<Element?, Never>? in
            guard !state.ended else { return nil }
            if let reader = state.reader {
                state.reader = nil
                return reader
            }
            state.items.append(item)
            return nil
        }
        condition.unlock()
        reader?.resume(returning: item)
    }

    /// The supervisor's single event pump suspends here when pairing consumption lags.
    func send(_ item: Element) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(item, continuation: continuation)
            }
        } onCancel: {
            self.cancelSend()
        }
    }

    private func enqueue(_ item: Element, continuation: CheckedContinuation<Void, Never>) {
        condition.lock()
        let (reader, accepted) = state.withLock { state -> (CheckedContinuation<Element?, Never>?, Bool) in
            guard !state.ended, !Task.isCancelled else { return (nil, true) }
            if let reader = state.reader {
                state.reader = nil
                return (reader, true)
            }
            if state.items.count < capacity {
                state.items.append(item)
                return (nil, true)
            }
            state.writer = (item, continuation)
            return (nil, false)
        }
        condition.unlock()
        reader?.resume(returning: item)
        if accepted { continuation.resume() }
    }

    private func cancelSend() {
        condition.lock()
        let writer = state.withLock { state in
            defer { state.writer = nil }
            return state.writer
        }
        condition.unlock()
        writer?.1.resume()
    }

    private func next() async -> Element? {
        await withCheckedContinuation { takeOrWait($0) }
    }

    private func takeOrWait(_ continuation: CheckedContinuation<Element?, Never>) {
        condition.lock()
        let (item, writer, ended) = state.withLock { state -> (Element?, CheckedContinuation<Void, Never>?, Bool) in
            if !state.items.isEmpty {
                let item = state.items.removeFirst()
                let writer = state.writer
                state.writer = nil
                if let writer { state.items.append(writer.0) }
                return (item, writer?.1, false)
            }
            if state.ended { return (nil, nil, true) }
            state.reader = continuation
            return (nil, nil, false)
        }
        condition.broadcast()
        condition.unlock()
        writer?.resume()
        if let item { continuation.resume(returning: item) }
        else if ended { continuation.resume(returning: nil) }
    }

    /// EOF preserves accepted lines; cancellation discards them and releases the pipe callback.
    func finish() { end(discard: false) }
    func cancel() { end(discard: true) }

    private func end(discard: Bool) {
        condition.lock()
        let (reader, writer) = state.withLock { state in
            state.ended = true
            if discard { state.items.removeAll() }
            let reader = state.reader
            state.reader = nil
            let writer = state.writer
            state.writer = nil
            return (reader, writer)
        }
        condition.broadcast()
        condition.unlock()
        reader?.resume(returning: nil)
        writer?.1.resume()
    }
}
