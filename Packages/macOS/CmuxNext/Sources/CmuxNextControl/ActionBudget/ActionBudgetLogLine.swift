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

    /// The line for `sample`, with the stack of its watchdog `over_budget` record: the one whose
    /// `task_owner` is the action and whose start is the run's (the run is published on the main-thread
    /// task board while it runs, and the watchdog samples it once it passes the budget).
    ///
    /// - Parameters:
    ///   - sample: The over-budget run.
    ///   - records: The watchdog's over-budget records (``MainThreadWatchdog/overBudget``).
    ///   - sampling: Whether this build samples over-budget tasks (``MainThreadWatchdog/recordsTaskBudgets(environment:)``).
    ///   - frames: Symbolicates a record's stack (``HangRecord/frames``; tests pass names).
    ///   - appImage: The app executable's image name, whose frames are the app's own work.
    public init(sample: ActionTimingSample, records: [HangRecord], sampling: Bool,
                frames: (HangRecord) -> [HangFrame] = { $0.frames },
                appImage: String? = Bundle.main.executableURL?.lastPathComponent) {
        var text = "action over budget: \(sample.id.rawValue) \(sample.entrypoint.rawValue) "
            + Self.format(sample.milliseconds) + " ms to commit"
        if let input = sample.inputToCommitMilliseconds { text += " (input " + Self.format(input) + " ms)" }
        let record = records.last { record in
            record.kind == .overBudget && record.startUptimeNanos == sample.startUptimeNanos
                && record.details["task_owner"] == .string(sample.id.rawValue)
        }
        if let record, !record.addresses.isEmpty {
            let resolved = frames(record)
            let app = resolved.filter { $0.image != nil && $0.image == appImage }.prefix(Self.appFrameCount)
            text += "; main: " + (resolved.first?.description ?? "?")
            if !app.isEmpty { text += " | app: " + app.map(\.description).joined(separator: " < ") }
            text += " (watchdog over_budget \(record.sequence))"
        } else if record != nil {
            text += "; no main-thread sample: the run ended before the watchdog sampled it"
        } else if sampling {
            text += "; no main-thread sample: the watchdog recorded no over-budget task for this run"
        } else {
            text += "; no main-thread sample: this build does not sample over-budget tasks"
        }
        self.text = text
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }
}
