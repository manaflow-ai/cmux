import AppKit
import Atomics
@testable import CmuxNextInput
import Darwin
import Testing

/// DIAGNOSTIC (probe branch only, never merged): where the tracked turn's allocations come from.
@MainActor
@Suite(.serialized) struct InputLatencyAllocationProbeTests {
    @Test("Allocation backtraces of one tracked and one idle turn")
    func allocationBacktraces() throws {
        let rig = try InputLatencyTrackerTests.AllocationRig()
        defer { rig.invalidate() }
        for _ in 0..<3 { rig.trackedTurn() }
        let idle = try #require(AllocTrace.capture { rig.idleTurn() })
        let tracked = try #require(AllocTrace.capture { rig.trackedTurn() })
        let report = "PROBE idle=\(idle.count) tracked=\(tracked.count)\n" + AllocTrace.report(tracked, label: "TRACKED")
            + "\n" + AllocTrace.report(idle, label: "IDLE")
        print(report)
        #expect(Bool(false), Comment(rawValue: report))
    }
}

private nonisolated struct AllocTrace {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    static let maxRecords = 8192
    static let depth = 28
    nonisolated(unsafe) static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxRecords * depth)
    nonisolated(unsafe) static let sizes = UnsafeMutablePointer<UInt>.allocate(capacity: maxRecords)
    static let recorded = ManagedAtomic<Int>(0)
    static let total = ManagedAtomic<Int>(0)
    static let inHook = ManagedAtomic<Bool>(false)
    static let thread = ManagedAtomic<UInt64>(0)

    struct Record { let size: UInt; let frames: [UnsafeMutableRawPointer?] }
    struct Capture { let count: Int; let records: [Record] }

    static func capture(_ body: () -> Void) -> Capture? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        recorded.store(0, ordering: .relaxed)
        total.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, arg2, arg3, _, _ in
            guard type & 2 != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            guard id == AllocTrace.thread.load(ordering: .relaxed) else { return }
            AllocTrace.total.wrappingIncrement(ordering: .relaxed)
            guard AllocTrace.inHook.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
            let index = AllocTrace.recorded.load(ordering: .relaxed)
            if index < AllocTrace.maxRecords {
                let base = AllocTrace.frames + index * AllocTrace.depth
                for i in 0..<AllocTrace.depth { base[i] = nil }
                _ = backtrace(base, Int32(AllocTrace.depth))
                AllocTrace.sizes[index] = type & 4 != 0 ? arg3 : arg2
                AllocTrace.recorded.store(index + 1, ordering: .relaxed)
            }
            AllocTrace.inHook.store(false, ordering: .relaxed)
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        let count = recorded.load(ordering: .relaxed)
        var records: [Record] = []
        for index in 0..<count {
            let base = frames + index * depth
            records.append(Record(size: sizes[index], frames: (0..<depth).map { base[$0] }))
        }
        return Capture(count: total.load(ordering: .relaxed), records: records)
    }

    typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                         UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    static func name(_ pc: UnsafeMutableRawPointer?) -> String {
        guard let pc else { return "-" }
        var info = Dl_info()
        guard dladdr(pc, &info) != 0, let sname = info.dli_sname else { return "\(pc)" }
        let raw = String(cString: sname)
        if let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") {
            let demangle = unsafeBitCast(fn, to: Demangle.self)
            if let out = demangle(sname, strlen(sname), nil, nil, 0) {
                defer { free(out) }
                return String(String(cString: out).prefix(160))
            }
        }
        return String(raw.prefix(160))
    }

    static func report(_ capture: Capture, label: String) -> String {
        var groups: [String: (count: Int, bytes: UInt)] = [:]
        for record in capture.records {
            // Skip the malloc/backtrace frames at the top.
            let names = record.frames.map(name).filter {
                !$0.hasPrefix("AllocTrace") && !$0.contains("closure #1 in static AllocTrace.capture")
                    && !$0.hasPrefix("malloc") && !$0.hasPrefix("_malloc") && !$0.hasPrefix("backtrace")
            }
            let key = names.prefix(14).joined(separator: "\n    ")
            let old = groups[key] ?? (0, 0)
            groups[key] = (old.count + 1, old.bytes + record.size)
        }
        var lines = ["== \(label): \(capture.count) allocations, \(groups.count) stacks"]
        for (key, value) in groups.sorted(by: { $0.value.count > $1.value.count }).prefix(25) {
            lines.append("-- \(value.count)x (\(value.bytes) bytes)\n    \(key)")
        }
        return lines.joined(separator: "\n")
    }
}
