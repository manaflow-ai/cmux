import AppKit
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
        client.activate()
        expiry.schedule(after: Self.maximumRun) { @MainActor [weak self] in self?.stop() }
    }

    private func stop() {
        client.deactivate()
        expiry.cancel()
    }

    private func tick(_ tick: FrameTick) {
        if let refresh = tick.refreshInterval { expected = refresh }
        if last > 0, intervals.count < Self.capacity { intervals.append((tick.timestamp - last) * 1_000) }
        last = tick.timestamp
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
        ]
    }
}

