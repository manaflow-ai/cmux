public import CmuxNextSettings
import Synchronization

/// One symbolicated return address from a main-thread stack sample.
public struct HangFrame: Sendable, Hashable {
    public var address: UInt
    public var image: String?
    public var symbol: String?
    public var offset: UInt

    public var description: String {
        let place = symbol.map { "\($0) + \(offset)" } ?? String(address, radix: 16)
        return "\(image ?? "?") \(place)"
    }
}

/// One main-thread stall longer than the watchdog threshold.
public struct HangRecord: Sendable, Hashable {
    public var sequence: UInt64
    /// `CLOCK_UPTIME_RAW` nanoseconds when the main thread stopped answering.
    public var startUptimeNanos: UInt64
    public var duration: Duration
    /// The main thread's stack, sampled once the stall crossed the
    /// threshold; empty when sampling failed or the stall ended first.
    public var frames: [HangFrame]

    public var json: JSONValue {
        [
            "sequence": JSONValue(Int(truncatingIfNeeded: sequence)),
            "start_uptime_ns": .number(Double(startUptimeNanos)),
            "duration_ms": .number(duration.fractionalMilliseconds),
            "frames": .array(frames.map { .string($0.description) }),
        ]
    }
}

/// Bounded ring buffer of hang records (drop-oldest).
public final class HangLog: Sendable {
    public struct Summary: Sendable, Equatable {
        public var count = 0
        public var maxDuration: Duration = .zero
        public var totalDuration: Duration = .zero
    }

    private struct State {
        var records: [HangRecord] = []
        var summary = Summary()
        var nextSequence: UInt64 = 1
    }

    public let capacity: Int
    private let state = Mutex(State())

    public init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    @discardableResult
    func append(startUptimeNanos: UInt64, duration: Duration, frames: [HangFrame]) -> HangRecord {
        state.withLock { state in
            let record = HangRecord(sequence: state.nextSequence, startUptimeNanos: startUptimeNanos, duration: duration, frames: frames)
            state.nextSequence += 1
            if state.records.count == capacity { state.records.removeFirst() }
            state.records.append(record)
            state.summary.count += 1
            state.summary.maxDuration = max(state.summary.maxDuration, duration)
            state.summary.totalDuration += duration
            return record
        }
    }

    /// Records newest last, optionally only those after `sequence`.
    public func records(after sequence: UInt64 = 0) -> [HangRecord] {
        state.withLock { $0.records.filter { $0.sequence > sequence } }
    }

    public var summary: Summary { state.withLock { $0.summary } }

    public func clear() {
        state.withLock { state in
            state.records.removeAll()
            state.summary = Summary()
        }
    }
}
