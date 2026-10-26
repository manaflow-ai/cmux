extension MainFrameBudget {
    /// What one frame knows about ``MainWorkClass/userBlocking``, the rest of a person's action
    /// (plans/cmux-next/chrome-parity/p06-scheduler.md, section 3A; Chrome kUserBlocking, above
    /// kUserVisible in `content/browser/scheduler/browser_task_queues.h`).
    ///
    /// ``MainFrameBudget/mayRun(_:)`` runs userBlocking before visible work. Pending input holds it
    /// as it holds visible (never two frames in a row), but the input response it answers and the
    /// typing burst do not: it is what the person waits for. Its first task of a frame always runs;
    /// past that it runs while it is under ``Budgets/userBlocking`` (the visible + automation
    /// shares) and the frame's limit, never on idle time.
    ///
    /// The progress rule: after a frame in which userBlocking reached its cap while visible work
    /// was deferred, the next frame runs only its first task. So a flood of it caps itself, and
    /// visible gets its whole share at least every second frame.
    ///
    /// The commit rule: a userBlocking task that ran while an input response was open answered
    /// that input, so the next render pass (its commit) closes the response
    /// (``MainFrameBudget/noteUserBlockingCommit()``). A frame-expecting input after the task opens
    /// a response the task did not answer.
    struct UserBlockingFrame {
        /// A userBlocking task ran while an input response was open: the next render pass closes it.
        var commitPending = false
        /// userBlocking reached its cap in this frame.
        private var cappedThisFrame = false
        /// Visible work was deferred over its budget in this frame.
        private var visibleDeferredThisFrame = false
        /// The last frame's userBlocking reached its cap while visible work was deferred: this frame
        /// userBlocking runs only its first task.
        private(set) var owesVisible = false

        /// A new frame window opened.
        mutating func roll() {
            owesVisible = cappedThisFrame && visibleDeferredThisFrame
            cappedThisFrame = false
            visibleDeferredThisFrame = false
        }

        /// Whether a task of `workClass`, past its first in the frame, may run: `underShare` says it is
        /// under its share and the frame under its limit. userBlocking also stops in a frame that owes
        /// visible its share; reaching its cap otherwise is remembered for the progress rule.
        mutating func mayContinue(_ workClass: MainWorkClass, underShare: Bool) -> Bool {
            guard workClass == .userBlocking else { return underShare }
            if owesVisible { return false }
            if !underShare { cappedThisFrame = true }
            return underShare
        }

        /// A task of `workClass` was deferred to the next frame.
        mutating func noteDeferred(_ workClass: MainWorkClass) {
            if workClass == .visible { visibleDeferredThisFrame = true }
        }

        /// A discrete input arrived: when it expects a frame, a userBlocking task before it answered
        /// an earlier input, and its commit does not close this one's response.
        mutating func noteInput(expectsFrame: Bool) {
            if expectsFrame { commitPending = false }
        }

        /// A render pass ended: whether it is the commit of a userBlocking task that answered the
        /// open input response.
        mutating func takeCommit() -> Bool {
            defer { commitPending = false }
            return commitPending
        }
    }
}
