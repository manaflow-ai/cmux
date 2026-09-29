import AppKit
import CmuxNextControl
import CmuxNextSettings
import QuartzCore

/// `debug.frames`: display-link frame intervals for the CLI storm bench.
/// Runs only between `start` and `stop` (an idle app keeps no display link).
/// A frame interval longer than the display's refresh period means the main
/// thread missed a vsync.
@MainActor
final class DebugFrameProbe: NSObject {
    private var link: CADisplayLink?
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
        guard link == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        expected = link.targetTimestamp - link.timestamp
        if last > 0, intervals.count < Self.capacity { intervals.append((link.timestamp - last) * 1_000) }
        last = link.timestamp
    }

    private var stats: JSONValue {
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        let budget = 1_000.0 / 60.0
        return [
            "running": .bool(link != nil),
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

extension DisplayLinkFrameScheduler: ControlFrameSource {}
