#if DEBUG
import CMUXDebugLog
import Dispatch
import Foundation
import os

/// Low-overhead, opt-in latency stamps for DEBUG host builds.
enum HostLatencyTrace {
    private static let writer = HostLatencyTraceWriter(capacity: 4_096)

    static let isEnabled =
        ProcessInfo.processInfo.environment["CMUX_LATENCY_TRACE"] == "1"
        || UserDefaults.standard.bool(forKey: "cmux.debug.latency-trace")

    @inline(__always)
    static func stamp(
        _ stage: StaticString,
        _ fields: @autoclosure () -> String = ""
    ) {
        guard isEnabled else { return }
        write(stage, uptimeMicroseconds: nowUptimeMicroseconds(), fields: fields())
    }

    @inline(__always)
    static func captureTime() -> UInt64? {
        guard isEnabled else { return nil }
        return nowUptimeMicroseconds()
    }

    @inline(__always)
    static func stampElapsed(
        _ stage: StaticString,
        since start: UInt64?,
        _ fields: (_ elapsedMicroseconds: UInt64) -> String
    ) {
        guard let start else { return }
        let completionTime = nowUptimeMicroseconds()
        write(
            stage,
            uptimeMicroseconds: completionTime,
            fields: fields(completionTime &- start)
        )
    }

    @inline(__always)
    private static func nowUptimeMicroseconds() -> UInt64 {
        // Simulator uptime is in the host Mac clock domain, so simulator and
        // Mac stamps are directly comparable. A physical iPhone is not.
        DispatchTime.now().uptimeNanoseconds / 1_000
    }

    @inline(__always)
    private static func write(
        _ stage: StaticString,
        uptimeMicroseconds: UInt64,
        fields: String
    ) {
        let suffix = fields.isEmpty ? "" : " \(fields)"
        writer.enqueue("LAT \(stage) t=\(uptimeMicroseconds)\(suffix)")
    }

    /// Fixed-capacity producer buffer for synchronous latency-trace call sites.
    private final class HostLatencyTraceWriter: Sendable {
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
                lines.reserveCapacity(
                    min(count, maximumCount) + (droppedCount > 0 ? 1 : 0)
                )
                if droppedCount > 0 {
                    let uptimeMicroseconds = DispatchTime.now().uptimeNanoseconds / 1_000
                    lines.append(
                        "LAT trace.dropped t=\(uptimeMicroseconds) n=\(droppedCount) side=mac"
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
        // lint:allow lock - latency stamps are synchronous hot-path callbacks;
        // this lock guards only bounded O(1) ring bookkeeping and never I/O.
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
                    appendSynchronously(batch)
                }
            }
        }

        private func appendSynchronously(_ batch: [String]) {
            guard let data = (batch.joined(separator: "\n") + "\n").data(using: .utf8) else {
                return
            }
            let fileDescriptor = open(
                CMUXDebugLog.DebugEventLog.currentLogPath(),
                O_WRONLY | O_APPEND | O_CREAT,
                0o644
            )
            guard fileDescriptor >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        }
    }
}
#endif
