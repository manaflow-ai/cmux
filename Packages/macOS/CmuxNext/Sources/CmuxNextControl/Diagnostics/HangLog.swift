public import CmuxNextSettings
import CmuxNextCompat

/// One symbolicated return address from a main-thread stack sample or an
/// exception trace (``StackSymbolicator``).
public struct HangFrame: Sendable, Hashable {
    public var address: UInt
    public var image: String?
    public var symbol: String?
    /// Offset into ``symbol``.
    public var offset: UInt
    /// Offset from the image's Mach-O header, which the build's dSYM resolves
    /// when there is no ``symbol``; nil when no image holds the address.
    public var imageOffset: UInt? = nil
    /// The image's `LC_UUID` (uppercase): the dSYM to resolve ``imageOffset`` with; nil when no
    /// image holds the address.
    public var imageUUID: String?

    /// The frame as structured JSON (`frame_details`): image, image UUID, offset from the image's
    /// header, and the symbol or null. The offset is there for a named frame too, so a reader
    /// that distrusts the name still resolves the frame from the dSYM.
    public var detailJSON: JSONValue {
        .object([
            "image": image.map(JSONValue.string) ?? .null,
            "image_uuid": imageUUID.map(JSONValue.string) ?? .null,
            "image_offset": imageOffset.map { .number(Double($0)) } ?? .null,
            "symbol": symbol.map(JSONValue.string) ?? .null,
        ])
    }

    public var description: String {
        let place = symbol.map { "\($0) + \(offset)" }
            ?? imageOffset.map { "+0x" + String($0, radix: 16) }
            ?? String(address, radix: 16)
        return "\(image ?? "?") \(place)"
    }
}

/// One main-thread stall longer than the watchdog threshold, or one busy
/// window (CPU with no input, animation or output; ``BusyWatchdog``).
public struct HangRecord: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case stall, busy
        /// A scheduled main-thread task that ran past its class's per-frame budget
        /// (``MainThreadWatchdog/overBudget``); its details name the task and class.
        case overBudget = "over_budget"
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
    public var frames: [HangFrame] { StackSymbolicator().frames(for: addresses) }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "sequence": JSONValue(Int(truncatingIfNeeded: sequence)),
            "kind": .string(kind.rawValue),
            "start_uptime_ns": .number(Double(startUptimeNanos)),
            "duration_ms": .number(duration.fractionalMilliseconds),
            "cpu_ms": .number(cpu.fractionalMilliseconds),
        ]
        let resolved = frames
        object["frames"] = .array(resolved.map { .string($0.description) })
        object["frame_details"] = .array(resolved.map(\.detailJSON))

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
            case .overBudget:
                state.summary.count += 1
                state.summary.maxDuration = max(state.summary.maxDuration, duration)
                state.summary.totalDuration += duration
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
