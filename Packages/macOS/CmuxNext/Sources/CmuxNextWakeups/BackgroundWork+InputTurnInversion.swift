import CmuxNextCompat

extension BackgroundWork {
    /// The runtime half of "main never awaits work started below userBlocking during an input turn"
    /// (plans/cmux-next/chrome-parity/p02-threads.md, section D, task 112; the static rule is task 113). In Debug
    /// and blocking-checks builds, an awaited item (``run(_:mayBlock:shutdown:fileID:line:_:)``,
    /// ``resolveHost(_:shutdown:fileID:line:_:)``, ``WorkSequence/run(_:shutdown:fileID:line:_:)``) stated below
    /// ``WorkPriority/userBlocking`` and awaited on the main
    /// thread while ``inputTurns`` runs ``MainWorkClass/input`` work (an action span of `ActionBudgetMonitor`, or a
    /// scheduled input task) records a ``CmuxNextCompat/BlockingKind/priorityInversion`` site at the caller's line.
    /// Record only: the boost at the call still runs the item at the caller's priority, but the stated priority
    /// is what a later edit, a post or a handle keeps, so the site names a call that should say `.userBlocking`
    /// (Chrome: work a person waits for is `TaskPriority::USER_BLOCKING`, base/task/task_traits.h).
    ///
    /// A posted item is never checked: nobody awaits it. Release compiles nothing here.
    @inline(__always)
    func noteAwaited(_ priority: WorkPriority, site: CallSite) {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        guard priority < .userBlocking, let board = inputTurns else { return }
        let packed = board.runningPacked.packed
        guard packed != 0, MainWorkClass(rawValue: Int(packed >> 56)) == .input else { return }
        recordAwaitedLowPriorityWork(fileID: site.fileID, line: site.line)
        #endif
    }
}
