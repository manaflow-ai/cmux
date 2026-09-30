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

/// One main-thread stall longer than the watchdog threshold, or one busy
/// window (CPU with no input, animation or output; ``BusyWatchdog``).
public struct HangRecord: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case stall, busy
    }

    public var sequence: UInt64
    public var kind: Kind = .stall
    /// `CLOCK_UPTIME_RAW` nanoseconds when the main thread stopped answering.
    public var startUptimeNanos: UInt64
    public var duration: Duration
    /// Main-thread CPU time during the stall. Close to `duration`: the main
    /// thread was busy (app work). Much lower: it was blocked in a wait, or
    /// descheduled on an overloaded machine.
    public var cpu: Duration
    /// Return addresses of the main thread's stack, sampled once the stall
    /// crossed the threshold; empty when sampling failed. Symbolicated only
    /// when read (``frames``), never on the main thread.
    public var addresses: [UInt]
    /// Busy records: scope, process, CPU share, busiest wakeup owners.
    public var details: [String: JSONValue] = [:]

    /// Symbolicated ``addresses``. Resolves symbols; call off the main thread.
    public var frames: [HangFrame] { ThreadStackSampler.symbolicate(addresses) }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "sequence": JSONValue(Int(truncatingIfNeeded: sequence)),
            "kind": .string(kind.rawValue),
            "start_uptime_ns": .number(Double(startUptimeNanos)),
            "duration_ms": .number(duration.fractionalMilliseconds),
            "cpu_ms": .number(cpu.fractionalMilliseconds),
            "frames": .array(frames.map { .string($0.description) }),
        ]
        object.merge(details) { current, _ in current }
        return .object(object)
    }
}

/// Bounded ring buffer of hang records (drop-oldest).
public final class HangLog: Sendable {
    public struct Summary: Sendable, Equatable {
        /// Stalls only; busy windows are counted in ``busyCount``.
        public var count = 0
        public var maxDuration: Duration = .zero
        public var totalDuration: Duration = .zero
        public var busyCount = 0
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
    func append(startUptimeNanos: UInt64, duration: Duration, cpu: Duration = .zero, addresses: [UInt],
                kind: HangRecord.Kind = .stall, details: [String: JSONValue] = [:]) -> HangRecord {
        state.withLock { state in
            let record = HangRecord(sequence: state.nextSequence, kind: kind, startUptimeNanos: startUptimeNanos, duration: duration,
                                    cpu: cpu, addresses: addresses, details: details)
            state.nextSequence += 1
            if state.records.count == capacity { state.records.removeFirst() }
            state.records.append(record)
            switch kind {
            case .stall:
                state.summary.count += 1
                state.summary.maxDuration = max(state.summary.maxDuration, duration)
                state.summary.totalDuration += duration
            case .busy:
                state.summary.busyCount += 1
            }
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
