public import Foundation
import os

/// The same-key calls of an approved Cloud create (or any approved op) after its approval was answered, while the
/// server still runs the op and answers `approval.pending` (the app's `CloudMachineCreateFlow`).
public nonisolated struct CloudApprovedRetry {
    public nonisolated init() {}
    /// 250 ms, 500 ms, then 1 s between the same-key calls. A pending call costs about 200 ms, and an op the server
    /// finishes while the flow waits is only seen at the next call: the old 1, 2, 4, 8 s (capped at 8 s) left a start
    /// whose server held the create 8 to 70 s waiting about 3.5 s past its machine (the chat probe's starts, 2026-11-21).
    public static func backoff(_ attempt: Int) -> Duration {
        switch attempt {
        case ...1: .milliseconds(250)
        case 2: .milliseconds(500)
        default: .seconds(1)
        }
    }

    /// The most same-key calls after the approval: enough that their backoffs add up to `patience`, so the flow's
    /// deadline ends the calls, and a clock that stands still still ends at this count.
    public static func waits(within patience: Duration) -> Int {
        var waited = Duration.zero, attempt = 1
        while waited < patience { waited += backoff(attempt); attempt += 1 }
        return attempt
    }

    /// The clock that marks the approval's parts of a measured start's `machine` step (``CloudStartSteps``): the wait
    /// for the create's `user.ensure`, then the approval's answer (its reads and `feed.answer`). None outside a start.
    @MainActor public static func steps() -> CloudStartSteps? {
        CloudStartStepRecord.current == nil ? nil : CloudStartSteps(logger: logger)
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
}
