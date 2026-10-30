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
    /// Stalls: the process's page faults while the stall ran, read on the watchdog thread after
    /// it ended (``HangLog/attach(_:toStallOfBeat:)``); nil until then, or when it could not be read.
    public var faults: StallFaults?
    /// The main thread's heartbeat that stalled (links the watchdog thread's fault window to this
    /// record); `.max` for records with no heartbeat.
    var beat: UInt64 = .max

    /// Why a stall took its wall time, by the debug hang assertion's rule: the main thread computed
    /// (CPU time at least half the wall time, `code`: a cmux fix names the stack's top frame) or it
    /// waited (`wait`: paging, a lock, an IPC reply, or the host did not schedule it; the stack
    /// shows only where the wait caught it, 30 ms in, not a site to optimize).
    public enum Cause: String, Sendable, Hashable {
        case code, wait

        init(cpu: Duration, wall: Duration) {
            self = cpu * 2 >= wall ? .code : .wait
        }
    }

    /// The cause of a stall (nil for busy and over-budget records).
    public var cause: Cause? {
        guard kind == .stall else { return nil }
        return Cause(cpu: cpu, wall: duration)
    }

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
        if let cause { object["cause"] = .string(cause.rawValue) }
        if let faults {
            object["task_faults"] = .number(Double(faults.faults))
            object["task_pageins"] = .number(Double(faults.pageins))
            object["fault_window_ms"] = .number(faults.window.fractionalMilliseconds)
        }
        let resolved = frames
        object["frames"] = .array(resolved.map { .string($0.description) })
        object["frame_details"] = .array(resolved.map(\.detailJSON))

        object.merge(details) { current, _ in current }
        return .object(object)
    }
}

/// The process's page faults over one stall (`task_events_info` deltas: the whole process, since
/// Darwin counts faults per task, not per thread). Many faults or page-ins in a `wait` stall say the
/// main thread waited for memory (swap or the compressor).
public struct StallFaults: Sendable, Hashable {
    /// Page faults (all kinds, zero-fill included).
    public var faults: UInt64
    /// Pages read in from disk or swap.
    public var pageins: UInt64
    /// The window the counts cover: from the watchdog thread's sample (30 ms into the stall at the
    /// default threshold) to its first pass after the stall ended (at most one threshold later).
    public var window: Duration
}

/// Bounded ring buffer of hang records (drop-oldest).
public final class HangLog: Sendable {
    public struct Summary: Sendable, Equatable {
        /// Stalls only; busy windows are counted in ``busyCount``.
        public var count = 0
        public var maxDuration: Duration = .zero
        public var totalDuration: Duration = .zero
        public var busyCount = 0
        /// Stalls by ``HangRecord/Cause`` (stalls only; ``count`` and ``totalDuration`` hold both).
        public var codeCount = 0
        public var codeDuration: Duration = .zero
        public var waitCount = 0
        public var waitDuration: Duration = .zero
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
                kind: HangRecord.Kind = .stall, details: [String: JSONValue] = [:], beat: UInt64 = .max) -> HangRecord {
        state.withLock { state in
            var record = HangRecord(sequence: state.nextSequence, kind: kind, startUptimeNanos: startUptimeNanos, duration: duration,
                                    cpu: cpu, addresses: addresses, details: details)
            record.beat = beat
            state.nextSequence += 1
            if state.records.count == capacity { state.records.removeFirst() }
            state.records.append(record)
            switch kind {
            case .stall:
                state.summary.count += 1
                state.summary.maxDuration = max(state.summary.maxDuration, duration)
                state.summary.totalDuration += duration
                if record.cause == .wait {
                    state.summary.waitCount += 1
                    state.summary.waitDuration += duration
                } else {
                    state.summary.codeCount += 1
                    state.summary.codeDuration += duration
                }
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

    /// Gives the stall of heartbeat `beat` its fault counts (the watchdog thread, after the stall
    /// ended). The stall is the newest record or close to it: the search stops at the first match.
    func attach(_ faults: StallFaults, toStallOfBeat beat: UInt64) {
        state.withLock { state in
            guard let index = state.records.lastIndex(where: { $0.beat == beat && $0.kind == .stall }) else { return }
            state.records.modify(checked: index) { $0.faults = faults }
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
