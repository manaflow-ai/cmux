import CmuxNextControl
import CmuxNextSettings
import Foundation
import ObjectiveC
import QuartzCore

/// `debug.terminal_display`: main-thread time in Ghostty's display passes (`-[IOSurfaceLayer display]`),
/// for the terminal resize bench (scripts/cmux-next/bench-terminal-resize.py,
/// ghostty-integration-DESIGN.md G1). A display pass runs when a host-sized terminal gets a new size;
/// before G1 each one drew a frame on the main thread and waited for the GPU.
///
/// `start` installs the timing override once (it stays for the process; unarmed it only forwards) and
/// clears the record; `stop` returns it: calls, their total and max ms, and passes (calls of one Core
/// Animation commit, consecutive within 1 ms) with their p50/p95/max ms.
@MainActor
final class DebugTerminalDisplayProbe {
    private var armed = false
    private var installed = false
    /// Per call: start (CACurrentMediaTime) and duration, seconds.
    private var calls: [(start: CFTimeInterval, duration: CFTimeInterval)] = []
    static let capacity = 200_000

    func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            calls.removeAll(keepingCapacity: true)
            armed = install()
            return .object(["armed": .bool(armed)])
        case "stop":
            let stats = stats()
            armed = false
            return stats
        default:
            return stats()
        }
    }

    fileprivate func record(start: CFTimeInterval, duration: CFTimeInterval) {
        guard armed, calls.count < Self.capacity else { return }
        calls.append((start, duration))
    }

    private func install() -> Bool {
        if installed { return true }
        guard let layerClass = NSClassFromString("IOSurfaceLayer"),
              let method = class_getInstanceMethod(layerClass, #selector(CALayer.display)) else { return false }
        typealias Display = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Display.self)
        let block = Self.timed(original, probe: self)
        method_setImplementation(method, imp_implementationWithBlock(block))
        installed = true
        return true
    }

    /// Built outside the main actor so the block carries no isolation check of its own.
    private nonisolated static func timed(_ original: @escaping @convention(c) (AnyObject, Selector) -> Void,
                                          probe: DebugTerminalDisplayProbe) -> @convention(block) (AnyObject) -> Void {
        { layer in
            let start = CACurrentMediaTime()
            original(layer, #selector(CALayer.display))
            let duration = CACurrentMediaTime() - start
            MainActor.assumeIsolated { // main-proof: Core Animation runs display passes on the main thread
                probe.record(start: start, duration: duration)
            }
        }
    }

    private func stats() -> JSONValue {
        var passes: [Double] = []
        var passEnd: CFTimeInterval = -1
        for call in calls {
            if passes.isEmpty || call.start - passEnd > 0.001 {
                passes.append(0)
            }
            passes[passes.count - 1] += call.duration * 1000
            passEnd = call.start + call.duration
        }
        let sorted = passes.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))]
        }
        let durations: [Double] = calls.map { $0.duration * 1000 }
        let total: Double = durations.reduce(0, +)
        var result: [String: JSONValue] = [:]
        result["armed"] = .bool(armed)
        result["calls"] = .number(Double(calls.count))
        result["total_ms"] = .number(total)
        result["max_call_ms"] = .number(durations.max() ?? 0)
        result["passes"] = .number(Double(passes.count))
        result["pass_p50_ms"] = .number(percentile(0.5))
        result["pass_p95_ms"] = .number(percentile(0.95))
        result["pass_max_ms"] = .number(sorted.last ?? 0)
        return .object(result)
    }
}
