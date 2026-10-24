public import CmuxNextActions
public import Foundation

/// The Debug log line for one over-budget action run: the action, its entrypoint, its times, and
/// the main-thread work that caused it, taken from the main-thread watchdog's stall sample that
/// overlaps the run (the watchdog is the one sampler; this adds none).
///
/// ```
/// action over budget: splitRight key 14.2 ms to commit (input 15.9 ms); main: AppKit ... | app: PaneController.split < ...
/// ```
public struct ActionBudgetLogLine: Sendable, Hashable {
    /// The line.
    public let text: String

    /// App frames shown from the stall's stack.
    static let appFrameCount = 4

    /// The line for `sample`, attributed to the first of `stalls` (the watchdog's records) whose
    /// interval overlaps the run's.
    ///
    /// - Parameters:
    ///   - sample: The over-budget run.
    ///   - stalls: The watchdog's stall records (newest last); empty when none overlap.
    ///   - threshold: The watchdog's stall threshold, named when no stall overlaps (a run shorter
    ///     than it has no sample), or nil when no watchdog runs.
    ///   - frames: Symbolicates a stall's stack (``HangRecord/frames``; tests pass names).
    ///   - appImage: The app executable's image name, whose frames are the app's own work.
    public init(sample: ActionTimingSample, stalls: [HangRecord], threshold: Duration?,
                frames: (HangRecord) -> [HangFrame] = { $0.frames },
                appImage: String? = Bundle.main.executableURL?.lastPathComponent) {
        var text = "action over budget: \(sample.id.rawValue) \(sample.entrypoint.rawValue) "
            + Self.format(sample.milliseconds) + " ms to commit"
        if let input = sample.inputToCommitMilliseconds { text += " (input " + Self.format(input) + " ms)" }
        let start = sample.startUptimeNanos, end = sample.startUptimeNanos &+ sample.nanos
        let stall = stalls.first { record in
            guard record.kind == .stall else { return false }
            let stallEnd = record.startUptimeNanos &+ UInt64(clamping: record.duration.nanoseconds)
            return record.startUptimeNanos < end && stallEnd > start && !record.addresses.isEmpty
        }
        if let stall {
            let resolved = frames(stall)
            let app = resolved.filter { $0.image != nil && $0.image == appImage }.prefix(Self.appFrameCount)
            text += "; main: " + (resolved.first?.description ?? "?")
            if !app.isEmpty { text += " | app: " + app.map(\.description).joined(separator: " < ") }
            text += " (watchdog stall \(stall.sequence), " + Self.format(stall.duration.fractionalMilliseconds) + " ms)"
        } else if let threshold {
            text += "; no main-thread sample: the watchdog samples stalls of "
                + Self.format(threshold.fractionalMilliseconds) + " ms or more (CMUX_NEXT_HANG_THRESHOLD_MS lowers it)"
        } else {
            text += "; no main-thread sample: no watchdog"
        }
        self.text = text
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }
}

private extension Duration {
    /// The duration in whole nanoseconds.
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
    }
}
