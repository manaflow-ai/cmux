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
///
/// From `start` to `stop` it also checks that each terminal changes size with its pane (the bench fails a drag or a
/// key resize that holds one, ``TerminalPaneFollowProbe``): `stop` adds `follow_frames` and `terminals_followed`.
@MainActor
public final class TerminalDisplayProbe {
    /// What `debug.terminal_display` answers (snake_case keys). The pane check's keys are only in `stop`'s reply.
    public nonisolated struct Report: Encodable, Sendable {
        public var armed: Bool
        public var calls: Int
        public var totalMs: Double
        public var maxCallMs: Double
        public var passes: Int
        public var passP50Ms: Double
        public var passP95Ms: Double
        public var passMaxMs: Double
        public var followFrames: Int?
        public var terminalsFollowed: [String: TerminalPaneFollowTally]?

        enum CodingKeys: String, CodingKey {
            case armed, calls, passes
            case totalMs = "total_ms", maxCallMs = "max_call_ms", passP50Ms = "pass_p50_ms", passP95Ms = "pass_p95_ms"
            case passMaxMs = "pass_max_ms", followFrames = "follow_frames", terminalsFollowed = "terminals_followed"
        }
    }

    private var armed = false
    private var installed = false
    /// Per call: start (CACurrentMediaTime) and duration, seconds.
    private var calls: [(start: CFTimeInterval, duration: CFTimeInterval)] = []
    static let capacity = 200_000
    private let follow = TerminalPaneFollowProbe()
    /// The app's live terminals by tab key (the content cache's), for the pane check; set by the app.
    public var terminals: @MainActor () -> [(key: String, session: TerminalSession)] = { [] }

    public init() {}

    /// `action`: "start", "stop", or anything else to read the record.
    public func handle(action: String?) -> Report {
        switch action ?? "read" {
        case "start":
            calls.removeAll(keepingCapacity: true)
            armed = install()
            follow.start(terminals())
            return report()
        case "stop":
            var report = report()
            armed = false
            follow.stop()
            report.followFrames = follow.frames
            report.terminalsFollowed = follow.tallies
            return report
        default:
            return report()
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
                                          probe: TerminalDisplayProbe) -> @convention(block) (AnyObject) -> Void {
        { layer in
            let start = CACurrentMediaTime()
            original(layer, #selector(CALayer.display))
            let duration = CACurrentMediaTime() - start
            MainActor.assumeIsolated { // main-proof: Core Animation runs display passes on the main thread
                probe.record(start: start, duration: duration)
            }
        }
    }

    private func report() -> Report {
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
        return Report(armed: armed, calls: calls.count, totalMs: durations.reduce(0, +), maxCallMs: durations.max() ?? 0,
                      passes: passes.count, passP50Ms: percentile(0.5), passP95Ms: percentile(0.95),
                      passMaxMs: sorted.last ?? 0)
    }
}
