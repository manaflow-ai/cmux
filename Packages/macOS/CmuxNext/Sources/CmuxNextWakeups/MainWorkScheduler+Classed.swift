public import CmuxNextCompat

/// Classed main-thread work that is not a Swift job (plans/cmux-next/chrome-parity/p04-input.md
/// section 3 (B), task 080): a GCD block, a run-loop block or a notification names its
/// ``MainWorkClass`` and an owner, so the scheduler can put a person's input first.
///
/// Unclassed, a `DispatchQueue.main.async` block or a run-loop callout runs in FIFO order with the
/// input. Classed, it goes by class:
///
/// - `input` and `frame` work runs at once: a callback in its own callout, a post on the next main
///   run loop turn (common modes, so a menu's tracking loop runs it too). Input work counts as
///   pending input on the board until it runs, so budgeted work yields to it.
/// - `userBlocking`, `visible`, `automation` and `background` work goes to its class queue, and
///   ``MainFrameBudget`` runs it when its class may.
/// - `idle` work goes to the ``IdleScheduler``.
///
/// Chrome posts every UI-thread task to a queue of its type and runs input first
/// (`content/browser/scheduler/browser_task_queues.h`, kUserInput), and Blink defers non-input
/// tasks while input is pending (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`).
///
/// ```swift
/// mainWork.post(class: .visible, owner: "sidebar.refresh") { sidebar.refresh() }
/// mainWork.postFromAnyThread(class: .input, owner: inputOwner) { editor.applyKey() }
/// observer = MainNotificationObserver(NSApplication.didChangeScreenParametersNotification, class: .visible,
///                                     owner: "screens.changed", on: mainWork) { [weak self] in self?.relayout() }
/// ```
extension MainWorkScheduler {
    /// Queues `body` to run on the main thread in `workClass`, never inline: the caller returns first.
    /// For a GCD or run-loop block on main (`DispatchQueue.main.async`, `CFRunLoopPerformBlock`).
    ///
    /// - Parameters:
    ///   - workClass: `input` for the rest of a person's input, `frame` for frame-locked work (both
    ///     on the next turn), `userBlocking`, `visible`, `automation` or `background`
    ///     (budgeted; see ``post(_:owner:file:line:_:)``), `idle` (the idle
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
            enqueue(budgeted, owner: owner, post: post, body)
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
    /// run loop turn, in the common modes. Input and frame work runs in that turn; the rest runs in
    /// that turn when its class may (``postFromAnyThread(_:owner:file:line:_:)``).
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
    /// Input and frame callbacks run there, as a task of their class on the board; the others run
    /// there when nothing is queued ahead of them and their class may run, else in a later turn or
    /// frame. A delivery runs only its own callback, never work
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

    // MARK: Internals

    /// A classed off-main post on the main thread, in its own run-loop turn (an arrival), or a classed
    /// callback in a helper's callout (`inCallout`), which may be inside another task: there only
    /// this callback runs, when its class queue is empty and its class may run, and otherwise it
    /// queues for the next turn or frame.
    func deliver(_ workClass: MainWorkClass, owner: MainTaskOwner, site: MainPostSite, enqueueNanos: UInt64?,
                 inCallout: Bool, _ body: @escaping @MainActor () -> Void) {
        let post = MainTaskPost(site: site, enqueueNanos: enqueueNanos ?? budget.nowNanos)
        if let budgeted = Self.budgeted(workClass) {
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
