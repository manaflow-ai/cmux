extension MainFrameBudget {
    /// The input-response state and the typing burst of ``MainFrameBudget``, on its clock
    /// (`CLOCK_UPTIME_RAW` nanoseconds).
    ///
    /// **Input response** (Chrome `main_thread_scheduler_impl.h`: `UseCase::kDiscreteInputResponse`,
    /// "waiting for the subsequent paint", and `RenderingPrioritizationState::kWaitingForInputResponse`,
    /// entered only when `is_frame_expected_after_discrete_input`). A discrete input (key down, mouse
    /// down) whose turn expects a frame opens it. It closes at the end of the first render pass of a
    /// display-link tick that began after the latest such input: the input's own turn commits before
    /// any tick of the link, so its commit never closes it. The open state asks the link for that
    /// tick (``MainWorkScheduler``), as Chrome's input asks the compositor for its BeginMainFrame.
    /// A user-blocking commit closes it too, and it never stays open past ``cap``. While it is open,
    /// automation and background wait.
    ///
    /// **Typing burst.** For ``burstLength`` after the latest discrete input, automation and
    /// background start at most one task per ``burstInterval`` (at most 10 a second), and once one
    /// interval has passed since the burst began or since the class's last task, that task runs
    /// even under pending input. An open input response holds it for one frame: the frame the
    /// person waits for goes first, so a due task runs at most one frame late (p06-scheduler.md,
    /// task 002, "Decision"). Visible keeps the budget's every-other-frame rule. Chrome
    /// defers its deferrable tasks for 2 s after a gesture (`TaskSchedulingInBlink.md`, "very likely
    /// that another gesture will arrive soon"); cmux keeps automation moving because agent and CLI
    /// requests have deadlines.
    struct InputResponse {
        /// The longest an input response stays open: Chrome's rendering-starvation threshold
        /// (`kDefaultRenderingStarvationThreshold`, 100 ms) bounds how long other work waits on a frame.
        static let cap: UInt64 = 100_000_000
        /// How long after the latest discrete input the typing-burst rate holds.
        static let burstLength: UInt64 = 500_000_000
        /// The typing-burst slot: at most one automation or background task per interval, and at
        /// least one once a whole interval passed.
        static let burstInterval: UInt64 = 100_000_000

        /// How an open input response ended.
        struct Closed: Equatable {
            /// How long it was open (``cap`` when it reached the cap).
            var nanos: UInt64
            /// It reached ``cap`` with no link-tick render and no user-blocking commit.
            var capped: Bool
        }

        /// What the typing burst says about a task of a burst class now.
        enum Burst: Equatable {
            /// No discrete input in the last ``burstLength``: the usual rules apply.
            case outside
            /// The class started a task less than ``burstInterval`` ago: it waits.
            case wait
            /// A whole interval passed since the burst began or the class's last task: it runs even
            /// under pending input; an open input response holds it for one frame.
            case due
            /// The rate allows a task, and progress is not owed yet: it runs only when no input is
            /// pending, no input response is open and its budget allows.
            case free
        }

        private var openedAt: UInt64?
        /// The link ticks counted when the latest frame-expecting input arrived.
        private var ticksAtInput: UInt64 = 0
        private var ticks: UInt64 = 0
        private var lastInput: UInt64?
        private var burstStart: UInt64 = 0
        /// Per budgeted class (``Stats/classes`` order): when its last task started.
        private var lastTaskStart: [UInt64?] = [nil, nil, nil, nil]
        /// Per budgeted class: when an open input response first held its due task.
        private var dueHeldSince: [UInt64?] = [nil, nil, nil, nil]

        /// Whether an input response is open at `now` (one open for ``cap`` or longer is not).
        func isOpen(at now: UInt64) -> Bool {
            guard let openedAt else { return false }
            return now &- openedAt < Self.cap
        }

        /// A discrete input arrived at `now`. It extends (or starts) the typing burst; when its
        /// turn expects a frame, it opens the input response, or makes an open one wait for a link
        /// tick after this input. Returns the response the cap closed first, if any.
        mutating func noteInput(expectsFrame: Bool, at now: UInt64) -> Closed? {
            let expired = expire(at: now)
            if !inBurst(at: now) {
                burstStart = now
                dueHeldSince = [nil, nil, nil, nil]
            }
            lastInput = now
            if expectsFrame {
                if openedAt == nil { openedAt = now }
                ticksAtInput = ticks
            }
            return expired
        }

        /// A display-link tick of the budget's scheduler began.
        mutating func noteTick() { ticks &+= 1 }

        /// A link tick's render pass ended: it closes the response when the tick began after the
        /// latest frame-expecting input.
        mutating func noteTickRenderEnded(at now: UInt64) -> Closed? {
            if let expired = expire(at: now) { return expired }
            guard ticks != ticksAtInput else { return nil }
            return close(at: now)
        }

        /// Closes an open response (a user-blocking commit showed the input's result). One that
        /// reached ``cap`` first closes as capped.
        mutating func close(at now: UInt64) -> Closed? {
            if let expired = expire(at: now) { return expired }
            guard let openedAt else { return nil }
            self.openedAt = nil
            return Closed(nanos: now &- openedAt, capped: false)
        }

        /// Closes a response open for ``cap`` or longer.
        mutating func expire(at now: UInt64) -> Closed? {
            guard let openedAt, now &- openedAt >= Self.cap else { return nil }
            self.openedAt = nil
            return Closed(nanos: Self.cap, capped: true)
        }

        /// A task of budgeted class `index` that started at `start` returned (a request: the batch
        /// around requests is not one).
        mutating func noteTask(_ index: Int, startedAt start: UInt64) {
            lastTaskStart[index] = start
            dueHeldSince[index] = nil
        }

        /// Whether an open input response still holds a due task of class `index` at `now`: it
        /// holds it through one frame (`frameNanos`, the refresh period), then the task runs. Under
        /// keys at 30 a second the next frame has no open response; at a key every frame this is
        /// what keeps the one task per interval moving.
        mutating func responseHoldsDue(_ index: Int, at now: UInt64, frameNanos: UInt64) -> Bool {
            // A hold more than two frames old is stale (the task did not come back): a new one.
            if let since = dueHeldSince[index], now &- since < frameNanos &* 2 {
                // Half a frame: the same tick holds, the next one runs, whatever its jitter.
                return now &- since < frameNanos / 2
            }
            dueHeldSince[index] = now
            return true
        }

        /// The typing-burst verdict for a task of budgeted class `index` at `now`. Both bounds use
        /// the whole interval, so they hold whether a task starts on a tick or between ticks: two
        /// starts are never less than ``burstInterval`` apart, and a task is due once a whole
        /// interval passed (on ticks, at the first frame on or after it).
        func burst(_ index: Int, at now: UInt64) -> Burst {
            guard inBurst(at: now) else { return .outside }
            let last = lastTaskStart[index]
            if let last, now &- last < Self.burstInterval { return .wait }
            let anchor = max(last ?? burstStart, burstStart)
            return now &- anchor >= Self.burstInterval ? .due : .free
        }

        private func inBurst(at now: UInt64) -> Bool {
            guard let lastInput else { return false }
            return now &- lastInput < Self.burstLength
        }
    }
}
