import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Where a main-thread task was posted: Chrome's `posted_from` (`FROM_HERE`, base/location.h).
/// The posting functions take it as `#fileID` and `#line` defaults; the board publishes it with
/// the running task (``MainTaskBoard/Task/postedFrom``).
public struct MainPostSite: Sendable {
    /// The posting file's `#fileID` (a static literal: kept by address, never copied).
    public let file: StaticString
    /// The posting line.
    public let line: UInt

    /// The site `file` (a `#fileID`) and `line`; the posting functions pass their defaults.
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
/// work posted while frames run, waits for the next frame. userBlocking and automation work also run
/// on the next turn while frames run: a person waits on the rest of their action, an agent's or the
/// CLI's request and reply are sequential, and Chrome's
/// sequence manager runs the next runnable task on the next pump iteration, never on vsync
/// (base/task/sequence_manager/thread_controller_with_message_pump_impl.cc). Only pending input or
/// its spent budget (``MainFrameBudget/mayRun(_:)``) holds it for a frame.
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
        /// Owner names interned on ``MainWorkScheduler/observations`` once each, so an observer built on main
        /// takes the ledger's lock only for a name's first instance.
        var observationOwners: [String: ObservationLedger.Owner] = [:]
        var hiddenWake: HiddenWake?
        /// Queues one turn (``MainRunLoopBlock`` in the app; a test's own queue in tests).
        var performTurn: TurnPerformer = { turn in MainRunLoopBlock.perform(turn) }
    }

    /// Queues one call of `turn` on a later main run loop turn, never inline.
    public typealias TurnPerformer = @MainActor (_ turn: @escaping @MainActor () -> Void) -> Void

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
    ///   - workClass: `userBlocking` for the rest of a person's action (a reply they wait on),
    ///     `visible` for screen updates no action of the person caused, `automation` for work an
    ///     agent, the CLI or another process asked for, `background` for work nobody sees (held while
    ///     the app launches, until ``StartupPhase`` reveals it).
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

    /// Queues `body`, the rest of a task that stopped between two chunks because
    /// ``MainFrameBudget/shouldYield()`` said so, at the front of `workClass`'s queue: Blink's
    /// `scheduler.yield()` continuation (third_party/blink/renderer/modules/scheduler/dom_scheduler.cc), which runs
    /// ahead of every task of its priority, posted before it or after. It runs in a later frame, first of its class,
    /// so the frame it stopped in renders and the person's pending input goes first: no drain runs it in the frame it
    /// was posted in, a turn drain of ``MainWorkClass/userBlocking`` or ``MainWorkClass/automation`` work included, so
    /// the task keeps to its class's share. Continuations run in the order they were posted. Never inline: the caller
    /// returns first. Post only the rest of a task that yielded; a new task is a ``post(_:owner:file:line:_:)``.
    ///
    /// - Parameters:
    ///   - workClass: The class of the task that yielded (its continuation keeps it).
    ///   - owner: The task's owner, interned on this scheduler's board (``MainTaskBoard/owner(_:)``).
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The rest of the task.
    public func postContinuation(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, file: StaticString = #fileID, line: UInt = #line,
                                 _ body: @escaping @MainActor () -> Void) {
        let post = MainTaskPost(site: MainPostSite(file: file, line: line), enqueueNanos: budget.nowNanos)
        classQueue(workClass).appendContinuation(owner: owner, post: post, body)
    }

    /// ``postContinuation(_:owner:file:line:_:)`` with an owner name, interned on the board once per scheduler.
    public func postContinuation(_ workClass: BudgetedWorkClass, owner: String, file: StaticString = #fileID, line: UInt = #line,
                                 _ body: @escaping @MainActor () -> Void) {
        postContinuation(workClass, owner: taskOwner(owner), file: file, line: line, body)
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
        let result: Result<T, E>
        do {
            result = try await withOnceContinuation { (continuation: OnceContinuation<Result<T, E>, OnceContinuationError>) in
                post(workClass, owner: interned, site: MainPostSite(file: file, line: line)) {
                    do throws(E) {
                        continuation.resume(returning: .success(try body()))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        } catch {
            // The class queue was released with the task unrun (abandoned): run it here, on main.
            return try body()
        }
        return try result.get()
    }

    /// Runs `body`, the main-thread part of a reply to work `cause` started, with `cause` as the
    /// current cause in ``causes``. A person's reply (the rest of their action, an
    /// `ActionRegistry` completion, a person-scope daemon reply) runs as one
    /// ``BudgetedWorkClass/userBlocking`` task (Chrome kUserBlocking,
    /// content/browser/scheduler/browser_task_queues.h); any other runs here, where it resumed.
    public func reply(as cause: ObservationCause, owner: String, file: StaticString = #fileID, line: UInt = #line,
                      _ body: @escaping @MainActor () -> Void) async {
        let causes = self.causes
        guard cause == .person else { return causes.withCause(cause) { body() } }
        await apply(.userBlocking, owner: owner, file: file, line: line) { causes.withCause(.person) { body() } }
    }

    /// Posted work of `workClass` not run yet, held by the launch or not (`debug.main_budget`, tests).
    public func postedCount(_ workClass: BudgetedWorkClass) -> Int {
        posting.queues.first { $0.workClass == workClass.workClass }?.count ?? 0
    }

    /// `name` interned on ``observations``, once per scheduler: an observer kind made per visible node (a tab
    /// title, a row) takes the ledger's lock once for its name, never per instance.
    public func observationOwner(_ name: String) -> ObservationLedger.Owner {
        if let owner = posting.observationOwners[name] { return owner }
        let owner = observations.owner(name)
        posting.observationOwners[name] = owner
        return owner
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
        post(workClass, owner: owner, post: MainTaskPost(site: site, enqueueNanos: budget.nowNanos), body)
    }

    /// Queues `body` as `post` (its site, enqueue time and node state: the board's ledger records
    /// its wait from that enqueue time). Nil: the task names its post itself when it runs one
    /// (``MainFrameBudget/notePost(_:)``, a node queue's pump). While classed work is held behind
    /// input, it is held behind that work (MainWorkScheduler+Classed.swift).
    func post(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, post: MainTaskPost?, _ body: @escaping @MainActor () -> Void) {
        if holdClassed(workClass, owner: owner, post: post, followsGate: false, body) { return }
        enqueue(workClass, owner: owner, post: post, body)
    }

    /// Appends `body` to its class queue, for the next turn or frame; never runs it inline.
    func enqueue(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, post: MainTaskPost?, _ body: @escaping @MainActor () -> Void) {
        let queue = classQueue(workClass)
        queue.append(owner: owner, post: post, body)
        if frames.hasLink {
            // The next frame runs it if the turn does not (the turn holds it, or a frame comes first).
            queue.activate()
            guard Self.runsOnNextTurn(queue.workClass) else { return }
        }
        if posting.turnQueued { return }
        posting.turnQueued = true
        posting.performTurn { [weak self] in self?.runPostedTurn() }
    }

    /// Reads the enqueue time here, on the posting thread (Chrome sets `PendingTask::queue_time` at
    /// `PostTask`, base/task/sequence_manager/task_queue_impl.cc), so the task's wait includes its
    /// time in the main run loop's queue.
    nonisolated func postFromAnyThread(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, site: MainPostSite,
                                       _ body: @escaping @MainActor @Sendable () -> Void) {
        let enqueueNanos = budget.postClock?()
        MainRunLoopBlock.perform { [weak self] in self?.arrive(workClass, owner: owner, site: site, enqueueNanos: enqueueNanos, body) }
    }

    /// A task posted off main reached the main thread, in its own run-loop turn: this turn is the
    /// next turn, so on an idle scheduler it runs now (in class order with anything else posted),
    /// not one more turn later. `enqueueNanos` is nil when the budget's clock is main-actor-only:
    /// the wait starts here.
    private func arrive(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, site: MainPostSite, enqueueNanos: UInt64?,
                        _ body: @escaping @MainActor () -> Void) {
        arrive(workClass, owner: owner, post: MainTaskPost(site: site, enqueueNanos: enqueueNanos ?? budget.nowNanos), body)
    }

    /// ``arrive(_:owner:site:enqueueNanos:_:)`` with its post made; a classed off-main post calls it
    /// too (MainWorkScheduler+Classed.swift). Held behind classed work held before it.
    func arrive(_ workClass: BudgetedWorkClass, owner: MainTaskOwner, post: MainTaskPost, _ body: @escaping @MainActor () -> Void) {
        if holdClassed(workClass, owner: owner, post: post, followsGate: false, body) { return }
        let queue = classQueue(workClass)
        queue.append(owner: owner, post: post, body)
        if frames.hasLink {
            if Self.runsOnNextTurn(queue.workClass) { runNow(queue) } else { queue.activate() }
            return
        }
        if posting.turnQueued { return }
        runPostedTurn()
    }

    /// The turn after the first post on an idle scheduler, or after an automation post while
    /// frames run: each class's queued work, in class order, while its class may run; the rest
    /// ticks on the next frames. A queue already ticking waits for its frame unless its class runs
    /// on the next turn (``runsOnNextTurn(_:)``); either way it drains from its head, so a task
    /// never runs twice and never passes work queued before it. A class the launch holds runs
    /// nothing here: its queue's client waits for the phase change.
    private func runPostedTurn() {
        posting.turnQueued = false
        for queue in posting.queues where queue.count > 0 && (!queue.isActive || Self.runsOnNextTurn(queue.workClass)) {
            runNow(queue)
        }
    }

    /// Runs `queue`'s work now while its class may run, and leaves the rest ticking on frames. After a
    /// tick whose batch waits for its own turn (after-commit placement), that turn runs it: right after
    /// the tick's commit, so the tick's turn holds no budgeted task.
    private func runNow(_ queue: FrameBatchQueue) {
        if !isBudgetTurnPending, startup.admits(queue.workClass), budget.mayRun(queue.workClass) { _ = queue.drainNow(limit: queue.count) }
        queue.activate()
    }

    /// Whether `workClass` runs on the next turn while frames run, not on the next frame:
    /// userBlocking, the rest of an action a person waits on, and automation, whose requests wait
    /// for their replies. Visible work stays on the frame that shows it, and background work has
    /// nobody waiting.
    private static func runsOnNextTurn(_ workClass: MainWorkClass) -> Bool {
        workClass == .userBlocking || workClass == .automation
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
