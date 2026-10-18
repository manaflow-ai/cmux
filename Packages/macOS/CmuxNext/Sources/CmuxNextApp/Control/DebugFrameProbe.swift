import AppKit
import ObjectiveC
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.frames`: display-link frame intervals for the CLI storm bench.
/// Runs only between `start` and `stop`, and at most `maximumRun` (a client
/// that never sends `stop` must not keep the display link running).
/// A frame interval longer than the display's refresh period means the main
/// thread missed a vsync.
@MainActor
final class DebugFrameProbe {
    static let maximumRun: Duration = .seconds(600)
    private lazy var client = FrameClient(owner: "debug.frames", isAnimation: false, on: .app) { [weak self] tick in
        self?.tick(tick)
        return true
    }
    private let expiry = DemandTimer(owner: "debug.frames.expiry")
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var expected: Double = 0
    static let capacity = 100_000

    func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            start()
        case "stop":
            let stats = self.stats
            stop()
            return stats
        case "reset":
            intervals.removeAll(keepingCapacity: true)
            last = 0
        default:
            break
        }
        return stats
    }

    private func start() {
        intervals.removeAll(keepingCapacity: true)
        last = 0
        CGSTransactionProbe.install()
        CGSTransactionProbe.stacks = [:]
        CGSTransactionProbe.calls = 0
        CGSTransactionProbe.recording = true
        client.activate()
        expiry.schedule(after: Self.maximumRun) { @MainActor [weak self] in self?.stop() }
    }

    private func stop() {
        CGSTransactionProbe.recording = false
        client.deactivate()
        expiry.cancel()
    }

    private func tick(_ tick: FrameTick) {
        if let refresh = tick.refreshInterval { expected = refresh }
        if last > 0, intervals.count < Self.capacity { intervals.append((tick.timestamp - last) * 1_000) }
        last = tick.timestamp
    }

    private var missedOffsets: [Double] {
        guard expected > 0 else { return [] }
        var offset = 0.0
        return intervals.compactMap { interval in
            offset += interval
            return interval > expected * 1_500 ? offset : nil
        }
    }

    private var stats: JSONValue {
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        let budget = 1_000.0 / 60.0
        return [
            "running": .bool(client.isActive),
            "frames": JSONValue(sorted.count),
            "refresh_ms": .number(expected * 1_000),
            "p50_ms": .number(percentile(0.5)),
            "p95_ms": .number(percentile(0.95)),
            "p99_ms": .number(percentile(0.99)),
            "max_ms": .number(sorted.last ?? 0),
            "over_16_7_ms": JSONValue(sorted.filter { $0 > budget }.count),
            // Missed vsyncs: intervals longer than 1.5 refresh periods.
            "missed": JSONValue(expected > 0 ? sorted.filter { $0 > expected * 1_500 }.count : 0),
            // When the missed vsyncs happened: ms from the first frame to the end of each (at most 16).
            "missed_at_ms": .array(missedOffsets.prefix(16).map { .number($0.rounded()) }),
            "cgs": CGSTransactionProbe.json,
        ]
    }
}


/// PROBE ONLY (perf-hitch cx-8w027.19, never landed): records the callers of
/// `+[_NSCGSTransaction currentTransaction]` between `debug.frames` start and stop when
/// CMUX_NEXT_PROBE_CGS=1, to find what opens a window-server transaction during a drag.
@MainActor
enum CGSTransactionProbe {
    static var recording = false
    static var stacks: [String: Int] = [:]
    static var calls = 0
    private static var installed = false
    nonisolated(unsafe) private static var original: IMP?

    static func install() {
        guard !installed, ProcessInfo.processInfo.environment["CMUX_NEXT_PROBE_CGS"] == "1",
              let cls = NSClassFromString("_NSCGSTransaction"),
              let method = class_getClassMethod(cls, NSSelectorFromString("currentTransaction")) else { return }
        installed = true
        original = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        let block: @convention(block) (AnyObject) -> AnyObject? = { me in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    if recording {
                        calls += 1
                        if stacks.count < 200 {
                            let key = Thread.callStackSymbols.dropFirst(1).prefix(28).map {
                                $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ")
                            }.joined(separator: " | ")
                            stacks[key, default: 0] += 1
                        }
                    }
                }
            }
            return unsafeBitCast(original!, to: Fn.self)(me, NSSelectorFromString("currentTransaction"))
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    static var json: JSONValue {
        ["calls": JSONValue(calls),
         "stacks": .array(stacks.sorted { $0.value > $1.value }.map { .string("\($0.value)x \($0.key)") })]
    }
}
