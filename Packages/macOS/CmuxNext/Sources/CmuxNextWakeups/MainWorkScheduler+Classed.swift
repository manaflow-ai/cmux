public import CmuxNextCompat
import CoreFoundation

/// Classed main-thread work that is not a Swift job (plans/cmux-next/chrome-parity/p04-input.md
/// section 3 (B), task 080): a GCD block, a run-loop block or a notification names its
/// ``MainWorkClass`` and an owner, so the scheduler can put a person's input first.
///
/// The ``MainJobGate`` sees only Swift main-actor jobs; a `DispatchQueue.main.async` block or a
/// run-loop callout runs beside it, in FIFO order with the input. Classed, it goes by class:
///
/// - `input` and `frame` work runs at once: a callback in its own callout, a post on the next main
///   run loop turn (common modes, so a menu's tracking loop runs it too). Input work counts as
///   pending input on the board until it runs, so budgeted work yields to it.
/// - `userBlocking`, `visible`, `automation` and `background` work waits while the gate says a
///   person's input is pending or in dispatch (``MainJobGateSwitch/holdsMainWork``), in one FIFO.
///   After the input's frame commits (the main run loop's `beforeWaiting`, after Core Animation's
///   commit) the FIFO goes to the class queues in order, and ``MainFrameBudget`` runs each when its
///   class may. One display refresh after the first was held, a precise ``wakeUps`` deadline sends
///   the FIFO on even while input is still pending and the run loop sleeps (the gate's starvation
///   bound). While the FIFO is not empty, every post of these classes appends to it, classed or not
///   (``post(_:owner:file:line:_:)``, ``postFromAnyThread(_:owner:file:line:_:)``, ``apply(_:owner:file:line:_:)``),
///   so each class keeps one FIFO and none overtakes work held before it.
/// - `idle` work goes to the ``IdleScheduler``.
///
/// Chrome posts every UI-thread task to a queue of its type and runs input first
/// (`content/browser/scheduler/browser_task_queues.h`, kUserInput), and Blink defers non-input
/// tasks while input is pending (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`).
///
/// ```swift
/// let jobGate = MainJobGateSwitch(pending: pending, holding: mainWork)  // the composition root
/// mainWork.post(class: .visible, owner: "sidebar.refresh") { sidebar.refresh() }
/// mainWork.postFromAnyThread(class: .input, owner: inputOwner) { editor.applyKey() }
/// observer = MainNotificationObserver(NSApplication.didChangeScreenParametersNotification, class: .visible,
///                                     owner: "screens.changed", on: mainWork) { [weak self] in self?.relayout() }
/// ```
extension MainWorkScheduler {
    /// Classed work of a budgeted class held behind a person's input, oldest first.
    struct ClassedHold {
        struct Entry {
            let workClass: BudgetedWorkClass
            let owner: MainTaskOwner
            let post: MainTaskPost?
            let body: @MainActor () -> Void
        }

        var entries: [Entry] = []
        /// Releases the entries after the input's commit; set while any is held.
        var commit: MainRunLoopObserver?
        /// Cancels the one-refresh deadline; set while any is held.
        var cancelDeadline: (@MainActor () -> Void)?
    }

    /// Calls `fire` on the main thread `delay` from now, waking the run loop, and returns what cancels it.
    typealias ClassedDeadlineArm = @MainActor (_ delay: Duration, _ fire: @escaping MainWakeUpQueue.Action) -> @MainActor () -> Void

    /// Classed work waits behind the input `gate` says is pending or in dispatch, while the gate is on.
    public func follow(_ gate: MainJobGateSwitch) {
        holdsClassedWork = { [weak gate] in gate?.holdsMainWork ?? false }
    }

    /// Queues `body` to run on the main thread in `workClass`, never inline: the caller returns first.
    /// For a GCD or run-loop block on main (`DispatchQueue.main.async`, `CFRunLoopPerformBlock`).
    ///
    /// - Parameters:
    ///   - workClass: `input` for the rest of a person's input, `frame` for frame-locked work (both
    ///     on the next turn, never held), `userBlocking`, `visible`, `automation` or `background`
    ///     (held behind input, then budgeted; see ``post(_:owner:file:line:_:)``), `idle` (the idle
    ///     periods, ``postIdle(owner:maxDelay:node:file:line:_:)``).
    ///   - owner: The task's owner in the board, the watchdog's records and signposts.
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The task.
    public func post(class workClass: MainWorkClass, owner: String, file: StaticString = #fileID, line: UInt = #line,
                     _ body: @escaping @MainActor () -> Void) {
        post(class: workClass, owner: taskOwner(owner), file: file, line: line, body)
    }

    /// ``post(class:owner:file:line:_:)`` with an owner already interned on this scheduler's board.
    public func post(class workClass: MainWorkClass, owner: MainTaskOwner, file: StaticString = #fileID, line: UInt = #line,
                     _ body: @escaping @MainActor () -> Void) {
        let site = MainPostSite(file: file, line: line)
        let post = MainTaskPost(site: site, enqueueNanos: budget.nowNanos)
        if let budgeted = Self.budgeted(workClass) {
            guard !holdClassed(budgeted, owner: owner, post: post, followsGate: true, body) else { return }
            enqueue(budgeted, owner: owner, post: post, body)
        } else if workClass == .idle {
            idle.post(owner: owner, site: site, maxDelay: nil, node: nil) { _ in body() }
        } else {
            if workClass == .input { board.inputQueued() }
            performTurn { [board, budget] in
                if workClass == .input { board.inputDone() }
                Self.runUnbudgeted(workClass, owner: owner, post: post, budget: budget, body)
            }
        }
    }

    /// ``post(class:owner:file:line:_:)`` from any thread: the task reaches main on the next main
    /// run loop turn, in the common modes. Input and frame work runs in that turn; the rest is held
    /// behind input, then runs in that turn when its class may (``postFromAnyThread(_:owner:file:line:_:)``).
    public nonisolated func postFromAnyThread(class workClass: MainWorkClass, owner: MainTaskOwner, file: StaticString = #fileID,
                                              line: UInt = #line, _ body: @escaping @MainActor @Sendable () -> Void) {
        let site = MainPostSite(file: file, line: line)
        let enqueueNanos = budget.postClock?()
        let board = board
        if workClass == .input { board.inputQueued() }
        MainRunLoopBlock.perform { [weak self] in
            if workClass == .input { board.inputDone() }
            self?.deliver(workClass, owner: owner, site: site, enqueueNanos: enqueueNanos, inCallout: false, body)
        }
    }

    /// The class a helper's callbacks run in (``MainActorObservation``, ``MainRunLoopBlock``,
    /// ``MainNotificationObserver``): each callback is delivered as it comes, in its own callout.
    /// Input and frame callbacks run there, as a task of their class on the board; the others are
    /// held behind input and run there when nothing is held or queued ahead of them and their class
    /// may run, else in a later turn or frame. A delivery runs only its own callback, never work
    /// posted before it: the callout may be inside another task. Without the scheduler (released) a
    /// callback runs at once.
    public nonisolated func callbackClass(_ workClass: MainWorkClass, owner: MainTaskOwner, file: StaticString = #fileID,
                                          line: UInt = #line) -> MainCallbackClass {
        let site = MainPostSite(file: file, line: line)
        return MainCallbackClass { [weak self] body in
            guard let self else { return body() }
            self.deliver(workClass, owner: owner, site: site, enqueueNanos: nil, inCallout: true, body)
        }
    }

    /// ``callbackClass(_:owner:file:line:)`` with an owner name, interned on this scheduler's board.
    public func callbackClass(_ workClass: MainWorkClass, owner: String, file: StaticString = #fileID,
                              line: UInt = #line) -> MainCallbackClass {
        callbackClass(workClass, owner: taskOwner(owner), file: file, line: line)
    }

    /// Classed work held behind input now.
    public var heldClassedCount: Int { classedHold.entries.count }

    // MARK: Internals

    /// A classed off-main post on the main thread, in its own run-loop turn (an arrival), or a classed
    /// callback in a helper's callout (`inCallout`), which may be inside another task: there only
    /// this callback runs, when its class queue is empty and its class may run, and otherwise it
    /// queues for the next turn or frame.
    func deliver(_ workClass: MainWorkClass, owner: MainTaskOwner, site: MainPostSite, enqueueNanos: UInt64?,
                 inCallout: Bool, _ body: @escaping @MainActor () -> Void) {
        let post = MainTaskPost(site: site, enqueueNanos: enqueueNanos ?? budget.nowNanos)
        if let budgeted = Self.budgeted(workClass) {
            if holdClassed(budgeted, owner: owner, post: post, followsGate: true, body) { return }
            guard inCallout else { return arrive(budgeted, owner: owner, post: post, body) }
            if postedCount(budgeted) == 0, startup.admits(workClass), budget.mayRun(workClass) {
                budget.run(workClass, owner: owner, posted: post) { body() }
            } else {
                enqueue(budgeted, owner: owner, post: post, body)
            }
        } else if workClass == .idle {
            idle.post(owner: owner, site: site, maxDelay: nil, node: nil) { _ in body() }
        } else {
            Self.runUnbudgeted(workClass, owner: owner, post: post, budget: budget, body)
        }
    }

    /// Holds a budgeted task behind work held before it, and with `followsGate` also while the gate
    /// holds; false when it goes on. Every budgeted post and arrival asks first, classed or not, so
    /// a class keeps one FIFO across the hold.
    func holdClassed(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, post: MainTaskPost?, followsGate: Bool,
                     _ body: @escaping @MainActor () -> Void) -> Bool {
        guard !classedHold.entries.isEmpty || (followsGate && holdsClassedWork()) else { return false }
        if classedHold.entries.isEmpty { armClassedRelease() }
        classedHold.entries.append(ClassedHold.Entry(workClass: workClass, owner: owner, post: post, body: body))
        return true
    }

    /// The main run loop's `beforeWaiting` while classed work is held, after the pass's commit: the
    /// held work goes once the gate no longer holds. Tests call it for the run loop.
    func classedHoldCommitted() {
        guard !holdsClassedWork() else { return }
        releaseClassed()
    }

    /// Sends the held work to its class queues, oldest first: after the input's commit, or at the
    /// one-refresh deadline though input is still pending.
    func releaseClassed() {
        guard !classedHold.entries.isEmpty else { return }
        let hold = classedHold
        classedHold = ClassedHold()
        hold.cancelDeadline?()
        for entry in hold.entries { enqueue(entry.workClass, owner: entry.owner, post: entry.post, entry.body) }
    }

    /// The first entry was held: watch for the commit, and arm the deadline one refresh from now.
    /// The deadline's timer wakes the run loop, so the bound holds also while the run loop sleeps
    /// with input still counted pending, or when this hold came inside a `beforeWaiting` callout.
    private func armClassedRelease() {
        classedHold.commit = MainRunLoopObserver(activities: .beforeWaiting, order: .max) { [weak self] _ in
            self?.classedHoldCommitted()
        }
        let refresh = Duration.nanoseconds(Int64(max(frames.refreshPeriod, 0) * 1_000_000_000))
        let fire: MainWakeUpQueue.Action = { [weak self] in self?.releaseClassed() }
        if let arm = armClassedDeadline {
            classedHold.cancelDeadline = arm(refresh, fire)
            return
        }
        let wakeUps = wakeUps
        let token = wakeUps.insert(owner: "MainWork.classedHold", after: refresh, policy: .precise, fire)
        classedHold.cancelDeadline = { _ = wakeUps.cancel(token) }
    }

    /// Runs input or frame work now, as a task of its class.
    private static func runUnbudgeted(_ workClass: MainWorkClass, owner: MainTaskOwner, post: MainTaskPost, budget: MainFrameBudget,
                                      _ body: @MainActor () -> Void) {
        budget.run(workClass, owner: owner, posted: post) { body() }
    }

    /// The budgeted class of `workClass`, or nil for input, frame and idle.
    private static func budgeted(_ workClass: MainWorkClass) -> BudgetedWorkClass? {
        switch workClass {
        case .userBlocking: .userBlocking
        case .visible: .visible
        case .automation: .automation
        case .background: .background
        case .input, .frame, .idle: nil
        }
    }
}

extension MainJobGateSwitch {
    /// ``init(pending:wakeUps:)`` on `mainWork`'s deadline queue, whose gate also holds `mainWork`'s
    /// classed work (``MainWorkScheduler/follow(_:)``).
    public convenience init(pending: SessionInputPending, holding mainWork: MainWorkScheduler) {
        self.init(pending: pending, wakeUps: mainWork.wakeUps)
        mainWork.follow(self)
    }

    /// Whether classed main work that is not input or frame waits now: the gate is on and a
    /// person's input is pending or in dispatch, outside a nested run loop.
    public var holdsMainWork: Bool { isEnabled && Self.holds(state.bits) }

    /// Whether the word `bits` holds classed main work (input pending or in dispatch, no nested
    /// loop, not bypassed).
    nonisolated static func holds(_ bits: InputPendingState.Bits) -> Bool {
        !bits.isDisjoint(with: .input) && bits.isDisjoint(with: [.nestedLoop, .bypass])
    }
}
