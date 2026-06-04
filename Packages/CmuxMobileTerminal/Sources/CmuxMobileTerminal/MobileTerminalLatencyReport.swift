#if canImport(UIKit) && DEBUG
import Foundation

/// One latency-probe run's results, written as JSON so the
/// `scripts/measure-ios-terminal-latency.sh` driver can diff runs across
/// refactor steps (see https://github.com/manaflow-ai/cmux/issues/5373).
///
/// Two phases feed it:
/// 1. **Typing latency** — keystrokes driven through the real soft-keyboard
///    input path (`TerminalInputTextView` → delegate → local echo →
///    `processOutput` → `ghostty_surface_process_output` → render), timed at
///    two checkpoints: bytes applied (`typingProcessed`) and the following
///    `render_now` completion (`typingRendered`).
/// 2. **Render cadence** — main-thread `CADisplayLink` frame intervals while
///    output streams at one line per frame (`cadenceFrameIntervals` + hitch
///    counts). A blocked main thread shows up as interval hitches here.
struct MobileTerminalLatencyReport: Codable, Sendable {
    /// Summary statistics over a set of millisecond samples.
    struct Distribution: Codable, Sendable {
        /// Number of samples aggregated.
        let count: Int
        /// Arithmetic mean in milliseconds.
        let meanMs: Double
        /// Median (50th percentile) in milliseconds.
        let p50Ms: Double
        /// 95th percentile in milliseconds.
        let p95Ms: Double
        /// Worst sample in milliseconds.
        let maxMs: Double

        /// Aggregates `samplesMs` (milliseconds). Empty input yields zeros.
        init(samplesMs: [Double]) {
            let sorted = samplesMs.sorted()
            count = sorted.count
            guard !sorted.isEmpty else {
                meanMs = 0
                p50Ms = 0
                p95Ms = 0
                maxMs = 0
                return
            }
            meanMs = sorted.reduce(0, +) / Double(sorted.count)
            p50Ms = Self.percentile(sorted, 0.50)
            p95Ms = Self.percentile(sorted, 0.95)
            maxMs = sorted[sorted.count - 1]
        }

        /// Percentile by rounded linear index over an ascending-sorted,
        /// non-empty array (`round((n-1)·q)`). Kept stable across probe runs
        /// so reports remain comparable; do not switch methods mid-series.
        private static func percentile(_ ascending: [Double], _ q: Double) -> Double {
            let index = Int((Double(ascending.count - 1) * q).rounded())
            return ascending[min(max(index, 0), ascending.count - 1)]
        }
    }

    /// Wall-clock capture time (seconds since 1970), for run bookkeeping.
    let capturedAtEpoch: Double
    /// `CMUX_LATENCY_PROBE_LABEL` if set (e.g. "baseline", "post-session-actor").
    let label: String
    /// Keystroke → `ghostty_surface_process_output` applied (main-actor hop).
    let typingProcessed: Distribution
    /// Keystroke → following `ghostty_surface_render_now` completion.
    let typingRendered: Distribution
    /// Main-thread display-link frame intervals during streaming output.
    let cadenceFrameIntervals: Distribution
    /// Cadence intervals exceeding 33 ms (a missed frame at 60 Hz).
    let cadenceHitchesOver33Ms: Int
    /// Cadence intervals exceeding 100 ms (user-visible stall).
    let cadenceHitchesOver100Ms: Int
    /// Whether the final verification read found the last echoed marker in
    /// `ghostty_surface_read_text` output (proves bytes really landed in the
    /// terminal grid, not just that callbacks fired).
    let surfaceTextVerified: Bool

    /// Serializes the report as pretty-printed, stable-key-ordered JSON.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
#endif
