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
///   class may. One display refresh after the first was held, the FIFO goes even while input is
///   still pending (the gate's starvation bound). While the FIFO is not empty, every new classed
///   post of these classes appends to it, so none overtakes one held before it.
/// - `idle` work goes to the ``IdleScheduler``.
///
/// Chrome posts every UI-thread task to a queue of its type and runs input first
/// (`content/browser/scheduler/browser_task_queues.h`, kUserInput), and Blink defers non-input
/// tasks while input is pending (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`).
///
/// ```swift
/// mainWork.follow(jobGate)                                    // the composition root
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
            let post: MainTaskPost
            let body: @MainActor () -> Void
        }

        var entries: [Entry] = []
        /// When the first entry was held (the budget's clock).
        var since: UInt64 = 0
        /// Releases the entries at the commit or the deadline; set while any is held.
        var release: MainRunLoopObserver?
    }

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
            if !holdClassed(budgeted, owner: owner, post: post, body) { self.post(budgeted, owner: owner, post: post, body) }
        } else if workClass == .idle {
            idle.post(owner: owner, site: site, maxDelay: nil, node: nil) { _ in body() }
        } else {
            if workClass == .input { board.inputQueued() }
            posting.performTurn { [board, budget] in
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
            self?.deliver(workClass, owner: owner, site: site, enqueueNanos: enqueueNanos, body)
        }
    }

    /// The class a helper's callbacks run in (``MainActorObservation``, ``MainRunLoopBlock``,
    /// ``MainNotificationObserver``): each callback is delivered as it comes, in its own callout.
    /// Input and frame callbacks run there, as a task of their class on the board; the others are
    /// held behind input and run there when nothing is held or queued ahead of them and their class
    /// may run, else in a later turn or frame. Without the scheduler (released) a callback runs at once.
    public nonisolated func callbackClass(_ workClass: MainWorkClass, owner: MainTaskOwner, file: StaticString = #fileID,
                                          line: UInt = #line) -> MainCallbackClass {
        let site = MainPostSite(file: file, line: line)
        return MainCallbackClass { [weak self] body in
            guard let self else { return body() }
            self.deliver(workClass, owner: owner, site: site, enqueueNanos: nil, body)
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

    /// A classed callback or an off-main post on the main thread, in its own turn.
    func deliver(_ workClass: MainWorkClass, owner: MainTaskOwner, site: MainPostSite, enqueueNanos: UInt64?,
                 _ body: @escaping @MainActor () -> Void) {
        let now = budget.nowNanos
        if let budgeted = Self.budgeted(workClass) {
            let post = MainTaskPost(site: site, enqueueNanos: enqueueNanos ?? now)
            if !holdClassed(budgeted, owner: owner, post: post, body) {
                arrive(budgeted, owner: owner, site: site, enqueueNanos: enqueueNanos, body)
            }
        } else if workClass == .idle {
            idle.post(owner: owner, site: site, maxDelay: nil, node: nil) { _ in body() }
        } else {
            Self.runUnbudgeted(workClass, owner: owner, post: MainTaskPost(site: site, enqueueNanos: enqueueNanos ?? now),
                               budget: budget, body)
        }
    }

    /// Holds a budgeted task while the gate holds or anything is held already; false when it goes on.
    private func holdClassed(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, post: MainTaskPost,
                             _ body: @escaping @MainActor () -> Void) -> Bool {
        guard !classedHold.entries.isEmpty || holdsClassedWork() else { return false }
        if classedHold.entries.isEmpty {
            classedHold.since = budget.nowNanos
            classedHold.release = MainRunLoopObserver(activities: [.beforeTimers, .beforeWaiting], order: .max) { [weak self] activity in
                self?.classedHoldStage(activity)
            }
        }
        classedHold.entries.append(ClassedHold.Entry(workClass: workClass, owner: owner, post: post, body: body))
        return true
    }

    /// A stage of the main run loop while classed work is held: after the pass's commit
    /// (`beforeWaiting`) it goes once the gate no longer holds; at any stage, once one refresh passed
    /// since the first was held. Tests call it for the run loop.
    func classedHoldStage(_ activity: CFRunLoopActivity) {
        guard !classedHold.entries.isEmpty else { return }
        let refreshNanos = UInt64(max(frames.refreshPeriod, 0) * 1_000_000_000)
        let overdue = budget.nowNanos &- classedHold.since >= refreshNanos
        guard overdue || (activity.contains(.beforeWaiting) && !holdsClassedWork()) else { return }
        let entries = classedHold.entries
        classedHold = ClassedHold()
        for entry in entries { post(entry.workClass, owner: entry.owner, post: entry.post, entry.body) }
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
    /// Whether classed main work that is not input or frame waits now: the gate is on and a
    /// person's input is pending or in dispatch, outside a nested run loop.
    public var holdsMainWork: Bool { isEnabled && Self.holdsMainWork(state.bits) }

    /// Whether the word `bits` holds classed main work (input pending or in dispatch, no nested
    /// loop, not bypassed).
    nonisolated static func holdsMainWork(_ bits: InputPendingState.Bits) -> Bool {
        !bits.isDisjoint(with: .input) && bits.isDisjoint(with: [.nestedLoop, .bypass])
    }
}
