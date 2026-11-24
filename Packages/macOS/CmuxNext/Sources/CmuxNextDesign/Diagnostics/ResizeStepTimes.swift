import Foundation

/// The main-thread time of each window resize step, by phase (`debug.layout_counters` `resize_steps`, DEBUG and bench
/// builds): a live resize sets the window's frame once per mouse event, and cmux's own layout runs inside that call. The
/// other Mac's samples (in-tree ON and OFF, 2026-11-24) put about half of all main-thread samples of a corner drag under
/// `ShellWindow.setFrame`, with 330-430 ms frames; a sample gives the shares, not which step was slow. This keeps one
/// entry per step: the whole `setFrame`, and inside it the root's `layout()` and its screens' fit.
/// A value kept by the layout root (`LayoutRootView.resizeSteps`), like its pass counters.
@MainActor
public struct ResizeStepTimes {
    /// One phase's milliseconds per step, the last ``capacity`` steps.
    public private(set) var phases: [String: [Double]] = [:]
    public static let capacity = 2_048

    public init() {}

    /// The time now, to pass to ``record(_:since:)`` after the phase's work. Two calls instead of one closure-taking
    /// `mutating` method: a phase measured inside another on the same value (the root's `layout()` inside
    /// `ShellWindow.setFrame`) then never holds the value across the inner one, which was a Swift exclusivity trap.
    public static func start() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Records the time since `start` under `phase` (DEBUG and bench builds; else nothing).
    public mutating func record(_ phase: String, since start: UInt64) {
        #if DEBUG || CMUX_BENCH_HOOKS
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        var list = phases[phase, default: []]
        if list.count >= Self.capacity { list.removeFirst(list.count - Self.capacity + 1) }
        list.append(ms)
        phases[phase] = list
        #endif
    }

    /// Per phase: steps, p50, p95, max and the ten slowest steps' indexes and times.
    public func report() -> [String: [String: Any]] {
        phases.mapValues { values in
            let sorted = values.sorted()
            func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
            let slowest = values.enumerated().sorted { $0.element > $1.element }.prefix(10).map { [Double($0.offset), $0.element] }
            return ["steps": values.count, "p50_ms": pct(0.5), "p95_ms": pct(0.95), "max_ms": sorted.last ?? 0,
                    "total_ms": values.reduce(0, +), "slowest": slowest]
        }
    }

    public mutating func reset() { phases.removeAll(keepingCapacity: true) }
}
