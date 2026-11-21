import Darwin
import Foundation
import Testing

// TickHarness: no soaks. Time, the network, memory pressure and the disk are
// scripted, so thousands of reconnects, deltas or events with hours between
// them run in seconds and replay exactly from a seed.
//
// - `TickRandom`: SplitMix64, the generator the acpmux simulation uses. One
//   seed drives the workload and every fault. `TICK_SEED=N` (or
//   `TEST_RUNNER_TICK_SEED` under xcodebuild) reruns one case.
// - `TickClock`: virtual time as a queue of events ordered by time, then by
//   the order they were scheduled. Nothing sleeps; `next(until:)` jumps.
// - `TickFaults`: what the scripted transport does to one message: lose it
//   (the sender waits out its timeout), deliver it twice, or deliver it late,
//   after messages sent after it.
// - `TickDisk`: a folder whose writes are refused for a while (made read only:
//   the same failed-write path a full disk takes), and its size in bytes.
// - `TickFootprint`: the process's `phys_footprint`, reported per operation.
//   Whole-process growth gates run in an isolated test run (the growth axis
//   of the reliability matrix); these cells gate on what the code under test
//   holds (rows in memory, rows and bytes on disk).
// - `TickReport`: one `MATRIX {json}` line per run, with the virtual time
//   covered, the wall time spent and the seed, for
//   scripts/ci/ios_reliability_matrix.py.

/// SplitMix64: small, fast, and the same sequence on every platform.
struct TickRandom: RandomNumberGenerator {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    mutating func chance(_ probability: Double) -> Bool { probability > 0 && unit() < probability }

    /// Uniform between the bounds, to the millisecond.
    mutating func duration(_ range: ClosedRange<Duration>) -> Duration {
        let low = range.lowerBound.tickMilliseconds, high = range.upperBound.tickMilliseconds
        return .milliseconds(low + Int64(unit() * Double(high - low)))
    }

    /// Log-uniform between the bounds: as many 100 ms blips as 8 h outages
    /// per decade, so one run covers every scale.
    mutating func logDuration(_ range: ClosedRange<Duration>) -> Duration {
        let low = log(Double(max(range.lowerBound.tickMilliseconds, 1)))
        let high = log(Double(max(range.upperBound.tickMilliseconds, 1)))
        return .milliseconds(Int64(exp(low + unit() * (high - low))))
    }

    /// The seed for a cell: `TICK_SEED` when set, else the cell's fixed one.
    static func seed(default fixed: UInt64) -> UInt64 {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["TICK_SEED"] ?? environment["TEST_RUNNER_TICK_SEED"],
              let seed = UInt64(text) else { return fixed }
        return seed
    }
}

/// Virtual time: events come out in time order (ties in the order they were
/// scheduled), and `now` jumps to each one. A binary heap, so a run with a
/// million timers stays O(log n) per event.
struct TickClock<Event> {
    private struct Entry {
        var at: Duration
        var order: Int
        var event: Event
        func before(_ other: Entry) -> Bool { at < other.at || (at == other.at && order < other.order) }
    }

    private(set) var now: Duration = .zero
    private(set) var processed = 0
    private var heap: [Entry] = []
    private var scheduled = 0

    var pending: Int { heap.count }

    mutating func schedule(_ event: Event, at time: Duration) {
        heap.append(Entry(at: max(time, now), order: scheduled, event: event))
        scheduled += 1
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].before(heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func schedule(_ event: Event, after delay: Duration) { schedule(event, at: now + delay) }

    /// The next event at or before `end`, with `now` moved to it; nil (and
    /// `now` at `end`) when none is due by then.
    mutating func next(until end: Duration) -> Event? {
        guard let first = heap.first, first.at <= end else {
            now = max(now, end)
            return nil
        }
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1, right = left + 1
                var smallest = parent
                if left < heap.count, heap[left].before(heap[smallest]) { smallest = left }
                if right < heap.count, heap[right].before(heap[smallest]) { smallest = right }
                guard smallest != parent else { break }
                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }
        now = first.at
        processed += 1
        return first.event
    }
}

/// The scripted transport's faults for one message. A lost message costs
/// its sender `timeout`; a duplicate is a second copy, usually late; a
/// reordered one arrives `lateBy` after it would have, so newer messages
/// overtake it.
struct TickFaults {
    var drop = 0.0
    var duplicate = 0.0
    var reorder = 0.0
    var latency: ClosedRange<Duration> = Duration.milliseconds(20)...(.milliseconds(400))
    var lateBy: ClosedRange<Duration> = Duration.milliseconds(500)...(.seconds(10))
    var timeout: Duration = .seconds(25)

    enum Delivery: Equatable {
        /// Never arrives; the sender gives up after `timeout`.
        case lost
        /// Arrives after each delay (two delays: a duplicate).
        case delivered([Duration])
    }

    /// Counts of what the faults did, for the report and the bounds.
    struct Counts: Equatable {
        var sent = 0, lost = 0, duplicated = 0, reordered = 0
    }

    func deliver(_ random: inout TickRandom, counts: inout Counts) -> Delivery {
        counts.sent += 1
        if random.chance(drop) {
            counts.lost += 1
            return .lost
        }
        var first = random.duration(latency)
        if random.chance(reorder) {
            counts.reordered += 1
            first += random.duration(lateBy)
        }
        guard random.chance(duplicate) else { return .delivered([first]) }
        counts.duplicated += 1
        return .delivered([first, first + random.duration(lateBy)])
    }
}

/// A folder the test can make refuse writes, the way a full disk does: the
/// code under test sees its writes fail, and must keep going and recover
/// when room comes back.
struct TickDisk {
    let directory: URL

    /// A new folder under tmp.
    init(name: String) throws {
        try self.init(directory: FileManager.default.temporaryDirectory
            .appending(path: "tick-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    /// A folder the code under test owns (a spill's): refused and allowed in place.
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes into the folder fail until `allow()`. Returns whether a probe
    /// write really failed (a test running as root could still write).
    @discardableResult
    func refuse() -> Bool {
        chmod(directory.path, 0o500)
        let probe = directory.appending(path: ".tick-probe")
        let wrote = FileManager.default.createFile(atPath: probe.path, contents: Data([1]))
        if wrote { try? FileManager.default.removeItem(at: probe) }
        return !wrote
    }

    func allow() { chmod(directory.path, 0o700) }

    /// Bytes in every file under the folder.
    func bytes() -> Int {
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in walk {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    func remove() {
        allow()
        try? FileManager.default.removeItem(at: directory)
    }
}

enum TickFootprint {
    /// The process's `phys_footprint` (Xcode's memory gauge), in bytes.
    static func bytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(bitPattern: info.phys_footprint) : 0
    }
}

/// Wall time, virtual time and footprint for one run, printed as one
/// `MATRIX` line and attached to the test.
struct TickReport {
    let cell: String
    let variant: String
    let seed: UInt64
    private let started = ContinuousClock.now
    private let footprintBefore = TickFootprint.bytes()

    init(cell: String, variant: String, seed: UInt64) {
        self.cell = cell
        self.variant = variant
        self.seed = seed
    }

    var wall: Duration { ContinuousClock.now - started }

    /// Prints the line and returns the wall time spent.
    @discardableResult
    func finish(ops: Int, virtual: Duration, _ fields: [String: Any]) -> Duration {
        let wall = self.wall
        let grown = TickFootprint.bytes() - footprintBefore
        var line = fields
        line["cell"] = cell
        line["variant"] = variant
        line["seed"] = String(seed)
        line["ops"] = ops
        line["virtual_h"] = (virtual.tickSeconds / 3600 * 10).rounded() / 10
        line["wall_ms"] = Int(wall.tickSeconds * 1000)
        line["footprint_bytes_per_op"] = ops > 0 ? Int(grown) / ops : 0
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("MATRIX \(text)")
            // The simulator route keeps attachments, not the runner's stdout.
            Attachment.record("MATRIX \(text)\n", named: "MATRIX-\(cell)-\(variant).txt")
        }
        return wall
    }
}

extension Duration {
    var tickMilliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
    var tickSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// FNV-1a over a run's trace: two runs from one seed must hash the same.
struct TickTrace {
    private(set) var hash: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func add(_ value: Int64) {
        var v = UInt64(bitPattern: value)
        for _ in 0..<8 {
            hash = (hash ^ (v & 0xFF)) &* 0x100_0000_01B3
            v >>= 8
        }
    }

}
