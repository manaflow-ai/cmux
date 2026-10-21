import Foundation

/// Frame timing measured inside the app (ACCEPTANCE M-FRAMELOG, G-04): the
/// display link's interval between consecutive frames, per phase of the
/// page (a finger or a deceleration owns it, following, reading) and
/// whether output was streaming. Screen recordings on a loaded laptop
/// cannot time frames; the app's own display link can.
public struct TerminalFrameStats: Equatable, Sendable {
    public struct Key: Hashable, Sendable, Comparable {
        public var phase: String
        public var streaming: Bool
        public init(phase: String, streaming: Bool) {
            self.phase = phase
            self.streaming = streaming
        }
        public static func < (a: Key, b: Key) -> Bool { (a.phase, a.streaming ? 1 : 0) < (b.phase, b.streaming ? 1 : 0) }
        public var label: String { phase + (streaming ? "+streaming" : "") }
    }

    public struct Summary: Equatable, Sendable {
        public var frames: Int
        public var p50Ms: Double
        public var p95Ms: Double
        public var p99Ms: Double
        public var maxMs: Double
        /// Intervals longer than 1.5 display frames: at least one frame missed.
        public var hitches: Int
        /// Main-thread time spent in the measured work per frame (p95, ms).
        public var workP95Ms: Double
    }

    /// The display's frame duration (1/60 or 1/120 s).
    public var frameDuration: Double
    private var intervals: [Key: [Double]] = [:]
    private var work: [Key: [Double]] = [:]

    public init(frameDuration: Double) { self.frameDuration = frameDuration }

    /// One frame: `interval` seconds since the previous one, `workMs` of
    /// main-thread work the screen did in it.
    public mutating func add(_ key: Key, interval: Double, workMs: Double = 0) {
        guard interval > 0 else { return }
        intervals[key, default: []].append(interval * 1000)
        work[key, default: []].append(workMs)
    }

    public var keys: [Key] { intervals.keys.sorted() }

    public func summary(_ key: Key) -> Summary? {
        guard let values = intervals[key]?.sorted(), !values.isEmpty else { return nil }
        let budget = frameDuration * 1000 * 1.5
        let workValues = (work[key] ?? []).sorted()
        return Summary(frames: values.count, p50Ms: Self.percentile(values, 0.5), p95Ms: Self.percentile(values, 0.95),
                       p99Ms: Self.percentile(values, 0.99), maxMs: values.last ?? 0,
                       hitches: values.filter { $0 > budget }.count,
                       workP95Ms: workValues.isEmpty ? 0 : Self.percentile(workValues, 0.95))
    }

    /// Nearest-rank percentile of sorted values.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    /// One line per key, for the log and the rig.
    public var report: String {
        keys.compactMap { key in
            summary(key).map { s in
                String(format: "%@ n=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f hitches=%d work_p95=%.2f", key.label, s.frames, s.p50Ms,
                       s.p95Ms, s.p99Ms, s.maxMs, s.hitches, s.workP95Ms)
            }
        }.joined(separator: "\n")
    }
}
