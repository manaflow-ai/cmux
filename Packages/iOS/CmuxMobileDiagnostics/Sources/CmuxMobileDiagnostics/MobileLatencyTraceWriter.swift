#if DEBUG
import Foundation
internal import os

/// Fixed-capacity producer buffer for synchronous latency-trace call sites.
final class MobileLatencyTraceWriter: Sendable {
    private struct State: Sendable {
        var entries: [String?]
        var head = 0
        var count = 0
        var droppedCount = 0
        var consumerStarted = false

        init(capacity: Int) {
            entries = Array(repeating: nil, count: capacity)
        }

        mutating func enqueue(_ line: String) {
            guard count < entries.count else {
                droppedCount += 1
                return
            }
            entries[(head + count) % entries.count] = line
            count += 1
        }

        mutating func drain(maximumCount: Int) -> [String]? {
            guard count > 0 || droppedCount > 0 else { return nil }
            var lines: [String] = []
            lines.reserveCapacity(min(count, maximumCount) + (droppedCount > 0 ? 1 : 0))
            if droppedCount > 0 {
                let uptimeMicroseconds = DispatchTime.now().uptimeNanoseconds / 1_000
                lines.append(
                    "LAT trace.dropped t=\(uptimeMicroseconds) n=\(droppedCount) side=ios"
                )
                droppedCount = 0
            }
            let drainedCount = min(count, maximumCount)
            for _ in 0..<drainedCount {
                if let line = entries[head] {
                    lines.append(line)
                }
                entries[head] = nil
                head = (head + 1) % entries.count
                count -= 1
            }
            return lines
        }
    }

    private static let batchSize = 128
    // lint:allow lock - trace stamps are synchronous hot-path callbacks; this
    // lock guards only bounded O(1) ring-buffer bookkeeping and never performs I/O.
    private let state: OSAllocatedUnfairLock<State>
    private let signals: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    init(capacity: Int) {
        precondition(capacity > 0)
        state = OSAllocatedUnfairLock(initialState: State(capacity: capacity))
        (signals, signalContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    @inline(__always)
    func enqueue(_ line: String) {
        let shouldStartConsumer = state.withLock { state in
            state.enqueue(line)
            guard !state.consumerStarted else { return false }
            state.consumerStarted = true
            return true
        }
        if shouldStartConsumer {
            Task.detached { [self] in
                await consume()
            }
        }
        signalContinuation.yield()
    }

    private func consume() async {
        for await _ in signals {
            while let batch = state.withLock({
                $0.drain(maximumCount: Self.batchSize)
            }) {
                await MobileDebugLog.shared.sink.appendBatch(batch)
            }
        }
    }
}
#endif
