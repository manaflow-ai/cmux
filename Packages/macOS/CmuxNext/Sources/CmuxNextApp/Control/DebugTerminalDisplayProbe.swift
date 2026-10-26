import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import ObjectiveC
import QuartzCore

/// `debug.terminal_display`: main-thread time in Ghostty's display passes (`-[IOSurfaceLayer display]`),
/// for the terminal resize bench (scripts/cmux-next/bench-terminal-resize.py,
/// ghostty-integration-DESIGN.md G1). A display pass runs when a host-sized terminal gets a new size;
/// before G1 each one drew a frame on the main thread and waited for the GPU.
///
/// Arms nest like RenderStats' (`debug.terminal_display` holds one, a `debug.damage` window another):
/// the first arm puts the timing override on the method, the last disarm puts the original IMP back
/// (R4 in p03-rendering.md), and neither tool clears or ends the other's counts. `start` marks where
/// its record begins; `stop` returns the record from that mark: calls, their total and max ms, and
/// passes (calls of one Core Animation commit, consecutive within 1 ms) with their p50/p95/max ms.
/// Past ``capacity`` stored calls the count goes on but no timing is kept, and the reply says `truncated`.
@MainActor
final class DebugTerminalDisplayProbe {
    /// The replaced method, its original IMP and the timing IMP.
    // SAFETY: a Method and the IMPs of a loaded class live for the process (IOSurfaceLayer is never
    // unloaded, and imp_implementationWithBlock's IMP is never removed), so these values never dangle.
    @safe private struct Hook {
        let method: Method
        let original: IMP
        let replacement: IMP
    }

    private var arms = 0
    private var hook: Hook?
    /// Calls recorded since launch; it never goes down.
    private var recorded = 0
    /// The ``recorded`` index of `calls[0]`: calls are stored from the first of the current arms.
    private var base = 0
    /// Per call: start (CACurrentMediaTime) and duration, seconds.
    private var calls: [(start: CFTimeInterval, duration: CFTimeInterval)] = []
    static let capacity = 200_000
    /// Set while `debug.terminal_display` holds its arm: the ``recorded`` index its record starts at.
    private var sessionMark: Int?
    /// The record of the last `stop`, for a `read` after it.
    private var lastStats: JSONValue?

    /// The class whose `display` is timed: Ghostty's `IOSurfaceLayer` (a test passes its own layer class).
    private let layerClassName: String

    init(layerClassName: String = "IOSurfaceLayer") {
        self.layerClassName = layerClassName
    }

    private var armed: Bool { arms > 0 }

    func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            if sessionMark != nil || arm() { sessionMark = recorded }
            return .object(["armed": .bool(sessionMark != nil)])
        case "stop":
            let result = stats()
            if sessionMark != nil {
                sessionMark = nil
                disarm()
            }
            lastStats = result
            return result
        default:
            return sessionMark == nil ? lastStats ?? stats() : stats()
        }
    }

    fileprivate func record(start: CFTimeInterval, duration: CFTimeInterval) {
        guard armed else { return }
        recorded += 1
        if calls.count < Self.capacity { calls.append((start, duration)) }
    }

    /// Holds one arm; the first puts the override on and starts a fresh store. False, holding
    /// nothing, when the method is not there.
    private func arm() -> Bool {
        if arms == 0 {
            guard install() else { return false }
            calls.removeAll(keepingCapacity: true)
            base = recorded
        }
        arms += 1
        return true
    }

    /// Ends one arm; the last puts the original IMP back where the override still runs (a swizzler
    /// that chained onto it keeps it, and the unarmed override only forwards).
    private func disarm() {
        guard arms > 0 else { return }
        arms -= 1
        // SAFETY: the hook's method and IMPs live for the process (Hook); the original IMP is the
        // method's own, so putting it back restores the signature the runtime expects.
        guard arms == 0, let hook, unsafe method_getImplementation(hook.method) == hook.replacement else { return }
        unsafe method_setImplementation(hook.method, hook.original)
    }

    /// Puts the override on; it is made again when the method's IMP is no longer the one it wraps.
    private func install() -> Bool {
        // SAFETY: `-[CALayer display]` takes no argument and returns void, so the method's IMP is
        // (self, _cmd) -> Void, the Display signature, and the cast changes no argument or return layout;
        // the timing block is that IMP's block form (self). Method and IMPs live for the process (Hook).
        guard let layerClass = NSClassFromString(layerClassName),
              let method = unsafe class_getInstanceMethod(layerClass, #selector(CALayer.display)) else { return false }
        let current = unsafe method_getImplementation(method)
        if let hook, unsafe hook.method == method, unsafe current == hook.replacement || current == hook.original {
            unsafe method_setImplementation(method, hook.replacement)
            return true
        }
        typealias Display = @convention(c) (AnyObject, Selector) -> Void
        let block = Self.timed(unsafe unsafeBitCast(current, to: Display.self), probe: self)
        let made = unsafe Hook(method: method, original: current, replacement: imp_implementationWithBlock(block))
        unsafe method_setImplementation(method, made.replacement)
        hook = made
        return true
    }

    /// No override runs on the method (none was put on, or the last disarm took it off).
    var isRestored: Bool {
        guard let hook else { return true }
        // SAFETY: the hook's method and IMP live for the process (Hook); this only compares them.
        return unsafe method_getImplementation(hook.method) != hook.replacement
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

    /// The record from the session's mark (from the first current arm when there is no session).
    private func stats() -> JSONValue {
        let mark = sessionMark ?? base
        let stored = calls[min(calls.count, max(0, mark - base))...]
        var passes: [Double] = []
        var passEnd: CFTimeInterval = -1
        for call in stored {
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
        let durations: [Double] = stored.map { $0.duration * 1000 }
        let total: Double = durations.reduce(0, +)
        var result: [String: JSONValue] = [:]
        result["armed"] = .bool(sessionMark != nil)
        result["calls"] = .number(Double(recorded - mark))
        result["truncated"] = .bool(recorded - mark > stored.count)
        result["total_ms"] = .number(total)
        result["max_call_ms"] = .number(durations.max() ?? 0)
        result["passes"] = .number(Double(passes.count))
        result["pass_p50_ms"] = .number(percentile(0.5))
        result["pass_p95_ms"] = .number(percentile(0.95))
        result["pass_max_ms"] = .number(sorted.last ?? 0)
        return .object(result)
    }
}

/// `debug.damage` counts Ghostty's display passes in its window through this probe, with an arm of its own.
extension DebugTerminalDisplayProbe: DisplayPassSource {
    var passCount: Int { recorded }

    func armPasses() -> Bool { arm() }

    func disarmPasses() { disarm() }
}
