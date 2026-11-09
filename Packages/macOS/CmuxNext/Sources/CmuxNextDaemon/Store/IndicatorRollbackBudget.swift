import Foundation
import os

/// The native half of the `[cmux perf budget]` warnings (cmuxterm-hq docs/handbook/perf-footguns.md,
/// class 1: a visible change that is not one state transition). A tab's dot shown read before its
/// owner answers, then rolled back, is two visible changes for nothing; repeated per input it is a
/// blink per key (Leo, 2026-11-09: "when im typing in the composer the tab and workspace flicker").
/// The web budgets never saw it: the tab strip and the sidebar row are native. Each rollback of an
/// optimistic tab indicator write is counted here, and more than ``limit`` of one kind on one tab
/// within ``window`` logs one warning naming the fix: send the write once per state, not per input.
/// Each ``TabModel`` holds its own (``TabModel/rollbacks``).
@MainActor
final class IndicatorRollbackBudget {
    let limit = 3
    let window: Duration = .seconds(2)
    /// Recent rollbacks, by kind.
    private var recent: [String: [ContinuousClock.Instant]] = [:]
    /// The kinds already warned about: one warning per kind.
    private var warned: Set<String> = []
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "perf-budget")
    /// What warned, for tests.
    private(set) var warnings: [String] = []

    /// `kind` (`notification-read`, `marked-unread`, `attention-clear`) rolled back on `tab`.
    func rolledBack(_ kind: String, tab: String, at now: ContinuousClock.Instant = .now) {
        var times = recent[kind, default: []].filter { now - $0 < window }
        times.append(now)
        recent[kind] = times
        guard times.count > limit, warned.insert(kind).inserted else { return }
        let line = "[cmux perf budget] indicator-rollback: \(kind) on tab \(tab) rolled back \(times.count) times in 2 s. "
            + "An optimistic indicator write sent per input against an owner that refuses it blinks the dot; "
            + "send it once per state (TabModel.takeKeystrokeRead)."
        warnings.append(line)
        logger.warning("\(line, privacy: .public)")
    }
}
