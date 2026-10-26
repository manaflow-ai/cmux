import CmuxNextCompat

/// Where a main-thread task was posted: Chrome's `posted_from` (`FROM_HERE`, base/location.h).
/// The posting functions take it as `#fileID` and `#line` defaults; the board publishes it with
/// the running task (``MainTaskBoard/Task/postedFrom``).
public struct MainPostSite: Sendable {
    /// The posting file's `#fileID` (a static literal: kept by address, never copied).
    public let file: StaticString
    /// The posting line.
    public let line: UInt

    public init(file: StaticString, line: UInt) {
        self.file = file
        self.line = line
    }
}

/// The posting API of the one main-thread scheduler (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// "Posting API"): Chrome's typed task runners (`content/browser/scheduler/browser_task_queues.h`,
/// `base/task/sequence_manager/task_queue_selector.h`) on the main thread.
///
/// Each budgeted class has one FIFO queue, built on its first post: a ``FrameBatchQueue`` on this
/// scheduler, so posted work runs in class order, one task at a time, while ``MainFrameBudget``
/// lets its class run, and yields to a person's pending input. Every task names its owner and its
/// posting site, which the board shows while it runs (the stall watchdog's record names both).
///
/// The first post after idle (no display link, no turn queued) runs on the next main run loop
/// turn when its class may run then, without waiting for a frame; work left after that turn, and
/// work posted while frames run, waits for the next frame.
///
/// ```swift
/// mainWork.post(.automation, owner: "browser-host.open") { host.open(url) }
/// let title = await mainWork.apply(.visible, owner: "pages.title") { page.title }
/// background.run(.userVisible, mayBlock: .files) { try Data(contentsOf: url) }
///     .reply(on: mainWork, class: .visible, owner: "preview.load") { result in preview.show(result) }
/// ```
extension MainWorkScheduler {
    /// The posting state: the class queues, ordered by class, and whether a turn is queued.
    struct Posting {
        var queues: [FrameBatchQueue] = []
        var turnQueued = false
        /// Owner names interned on the board once each, so a post on main takes no lock after the first.
        var owners: [String: MainTaskOwner] = [:]
        var hiddenWake: HiddenWake?
    }

    /// Asks for one call of `wake` at the next aligned hidden wake-up (1 s boundaries, Blink's
    /// `WakeUpBudgetPool::GetNextAllowedWakeUp` in
    /// third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.cc), on the
    /// main actor. `owner` names who asked in the wakeup ledger.
    public typealias HiddenWake = @MainActor (_ owner: String, _ wake: @escaping @MainActor () -> Void) -> Void

    /// Where hidden nodes' background queues (``MainTaskQueue``) get their aligned wakes; the
    /// composition root sets it once, from its aligned wake-up source. While it is nil, background
    /// tasks of a hidden node are held until the node shows.
    public var hiddenWake: HiddenWake? {
        get { posting.hiddenWake }
        set { posting.hiddenWake = newValue }
    }

    /// Queues `body` to run on the main thread in `workClass`, after the work posted before it in
    /// that class. Never inline: the caller returns first.
    ///
    /// It runs whether or not anyone can see its owner. An owner that can be hidden (a tab, a
    /// workspace, a row, a page) posts through its node's queue instead
    /// (``VisibilityNode/queue(_:owner:on:)``), which holds the work while the node is hidden; a
    /// plain post from such an owner carries a `// node-free: <why it must run while hidden>` comment.
    ///
    /// - Parameters:
    ///   - workClass: `visible` for screen updates no action of the person caused, `automation` for
    ///     work an agent, the CLI or another process asked for, `background` for work nobody sees
    ///     (held while the app launches, until ``StartupPhase`` reveals it).
    ///   - owner: The task's owner in the board, the watchdog's records and signposts.
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The task.
    public func post(_ workClass: BudgetedWorkClass, owner: String, file: StaticString = #fileID, line: UInt = #line,
                     _ body: @escaping @MainActor () -> Void) {
        post(workClass, owner: taskOwner(owner), site: MainPostSite(file: file, line: line), body)
    }

    /// ``post(_:owner:file:line:_:)`` with an owner already interned on this scheduler's board
    /// (``MainTaskBoard/owner(_:)``): for a poster that posts per key or per frame.
    public func post(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, file: StaticString = #fileID, line: UInt = #line,
                     _ body: @escaping @MainActor () -> Void) {
        post(workClass, owner: owner, site: MainPostSite(file: file, line: line), body)
    }

    /// ``post(_:owner:file:line:_:)`` from any thread: the task reaches main on the next main run
    /// loop turn, in the common modes (so a menu's tracking loop does not hold it), and that turn is
    /// its first chance to run. Main-actor code calls ``post(_:owner:file:line:_:)`` instead, which
    /// queues the task behind work posted before it at once.
    public nonisolated func postFromAnyThread(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, file: StaticString = #fileID,
                                              line: UInt = #line, _ body: @escaping @MainActor @Sendable () -> Void) {
        postFromAnyThread(workClass, owner: owner, site: MainPostSite(file: file, line: line), body)
    }

    /// ``postFromAnyThread(_:owner:file:line:_:)`` with an owner name, interned on the board on the
    /// calling thread (a lock: from main, prefer an interned ``MainTaskOwner``).
    public nonisolated func postFromAnyThread(_ workClass: BudgetedWorkClass, owner: String, file: StaticString = #fileID,
                                              line: UInt = #line, _ body: @escaping @MainActor @Sendable () -> Void) {
        postFromAnyThread(workClass, owner: board.owner(owner), site: MainPostSite(file: file, line: line), body)
    }

    /// Runs `body` on the main thread in `workClass`, as ``post(_:owner:file:line:_:)`` queues it, and
    /// returns what it returns. Use the reply form (``BackgroundWork/Pending/reply(on:class:owner:file:line:_:)``)
    /// where it fits: the caller's resume after this await is one more main-actor job the board does
    /// not attribute.
    public func apply<T: Sendable, E: Error>(_ workClass: BudgetedWorkClass, owner: String, file: StaticString = #fileID,
                                             line: UInt = #line, _ body: @escaping @MainActor () throws(E) -> T) async throws(E) -> T {
        startup.checkAwait(workClass.workClass, owner: owner, file: file, line: line)
        let interned = taskOwner(owner)
        let result: Result<T, E> = await withCheckedContinuation { continuation in
            post(workClass, owner: interned, site: MainPostSite(file: file, line: line)) {
                do throws(E) {
                    continuation.resume(returning: .success(try body()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }

    /// Posted work of `workClass` not run yet, held by the launch or not (`debug.main_budget`, tests).
    public func postedCount(_ workClass: BudgetedWorkClass) -> Int {
        posting.queues.first { $0.workClass == workClass.workClass }?.count ?? 0
    }

    // MARK: Internals

    /// `name` interned on the board, once per scheduler.
    func taskOwner(_ name: String) -> MainTaskOwner {
        if let owner = posting.owners[name] { return owner }
        let owner = board.owner(name)
        posting.owners[name] = owner
        return owner
    }

    func post(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, site: MainPostSite, _ body: @escaping @MainActor () -> Void) {
        let queue = classQueue(workClass)
        queue.append(owner: owner, site: site, body)
        if posting.turnQueued { return }
        if frames.hasLink {
            queue.activate()
            return
        }
        posting.turnQueued = true
        MainRunLoopBlock.perform { [weak self] in self?.runPostedTurn() }
    }

    nonisolated func postFromAnyThread(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, site: MainPostSite,
                                       _ body: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopBlock.perform { [weak self] in self?.arrive(workClass, owner: owner, site: site, body) }
    }

    /// A task posted off main reached the main thread: this turn is the next turn, so on an idle
    /// scheduler it runs now (in class order with anything else posted), not one more turn later.
    private func arrive(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, site: MainPostSite, _ body: @escaping @MainActor () -> Void) {
        let queue = classQueue(workClass)
        queue.append(owner: owner, site: site, body)
        if posting.turnQueued { return }
        if frames.hasLink {
            queue.activate()
            return
        }
        runPostedTurn()
    }

    /// The turn after the first post on an idle scheduler: each class's queued work, in class
    /// order, while its class may run; the rest ticks on the next frames. A queue already ticking
    /// waits for its frame, so a task never runs twice and never passes work queued before it. A
    /// class the launch holds runs nothing here: its queue's client waits for the phase change.
    private func runPostedTurn() {
        posting.turnQueued = false
        for queue in posting.queues where queue.count > 0 && !queue.isActive {
            if startup.admits(queue.workClass), budget.mayRun(queue.workClass) { _ = queue.drainNow(limit: queue.count) }
            queue.activate()
        }
    }

    /// The class's queue, built on its first post.
    private func classQueue(_ workClass: BudgetedWorkClass) -> FrameBatchQueue {
        let mainClass = workClass.workClass
        if let queue = posting.queues.first(where: { $0.workClass == mainClass }) { return queue }
        let queue = FrameBatchQueue(owner: "MainWork.\(mainClass)", budgeted: workClass, on: self)
        let index = posting.queues.firstIndex { $0.workClass > mainClass } ?? posting.queues.count
        posting.queues.insert(queue, at: index)
        return queue
    }
}
