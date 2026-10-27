extension MainFrameBudget {
    /// The discrete input an action run answers: the outermost input dispatch in progress when the
    /// run started (``MainFrameBudget/answerableInput``). A userBlocking completion of that run hands
    /// it back (``MainFrameBudget/noteAnswered(_:)``), so its commit closes that input's response and
    /// no other.
    public nonisolated struct InputToken: Sendable, Hashable {
        let serial: UInt64
    }

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
    /// The commit rule: the response stays open until the first link-tick render after its input
    /// (``MainFrameBudget/noteTickRenderEnded()``), or until the commit of the async completion
    /// that answers that input, whichever is first. A completion answers it when it names the
    /// input's dispatch (``InputToken``) and runs after the input's own turn committed, so neither
    /// the input's own commit, nor a person-caused flush, nor an earlier input's reply closes it.
    struct UserBlockingFrame {
        /// A completion answered the open response: the next render pass (its commit) closes it.
        private(set) var commitPending = false
        /// userBlocking reached its cap in this frame.
        private var cappedThisFrame = false
        /// Visible work was deferred over its budget in this frame.
        private var visibleDeferredThisFrame = false
        /// The last frame's userBlocking reached its cap while visible work was deferred: this frame
        /// userBlocking runs only its first task.
        private(set) var owesVisible = false
        /// The outermost discrete dispatch in progress, or the last one.
        private var dispatchSerial: UInt64 = 0
        /// The dispatch whose frame-expecting input opened the response; nil when that input came
        /// from no dispatch (an injected key), which no completion answers.
        private var responseInput: UInt64?
        /// A render pass ended since that input: its own turn committed.
        private var inputCommitted = false

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

        /// A discrete dispatch began; `outermost` when no other was in progress.
        mutating func noteDispatchBegan(outermost: Bool) {
            if outermost { dispatchSerial &+= 1 }
        }

        /// The input an action run starting now answers: the dispatch in progress, if any.
        func answerable(dispatchOpen: Bool) -> InputToken? {
            dispatchOpen ? InputToken(serial: dispatchSerial) : nil
        }

        /// A discrete input arrived, in a dispatch or not. One that expects a frame is the input the
        /// response now waits on: an answer to an earlier input no longer closes it.
        mutating func noteInput(expectsFrame: Bool, inDispatch: Bool) {
            guard expectsFrame else { return }
            commitPending = false
            responseInput = inDispatch ? dispatchSerial : nil
            inputCommitted = false
        }

        /// A completion of a run started in `input`'s dispatch ran: its commit closes the open
        /// response when `input` opened it and that input's own turn already committed.
        mutating func noteAnswered(_ input: InputToken, responseOpen: Bool) {
            if responseOpen, inputCommitted, input.serial == responseInput { commitPending = true }
        }

        /// A render pass ended: whether it is the commit of a completion that answered the open
        /// response. Either way the open input's own turn has committed now.
        mutating func takeCommit() -> Bool {
            defer {
                commitPending = false
                inputCommitted = true
            }
            return commitPending
        }
    }
}
