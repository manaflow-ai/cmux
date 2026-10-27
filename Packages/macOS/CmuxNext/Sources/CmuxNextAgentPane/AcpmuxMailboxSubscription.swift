public import CmuxNextWakeups

/// Runs one ``AcpmuxMailboxReader`` at a time for a main-actor owner and gives
/// it only the pages of the reader that is current.
///
/// The reader runs off the main actor, and each page it reads reaches the main
/// actor as one task of the owner's class on the app's ``MainWorkScheduler``
/// (Chromium's `PostTaskAndReply` onto a typed UI task runner,
/// content/browser/scheduler/browser_task_queues.h), in the order read. The
/// owner can stop or replace the reader before that task runs (a sign-out,
/// another account): cancelling the reader's task does not stop a page already
/// posted. The subscription numbers each reader, and a page whose reader is no
/// longer current is dropped on the main actor, where the owner's own reset
/// runs, so no page of a stopped reader is applied after the reset (another
/// person's reports never show).
///
/// ```swift
/// private let reports = AcpmuxMailboxSubscription(mainWork: mainWork, workClass: .automation, owner: "FeedService.reports")
/// reports.start(reader) { [weak self] page in self?.apply(page) }
/// reports.stop() // sign-out: no later page of that reader is applied
/// ```
@MainActor
public final class AcpmuxMailboxSubscription {
    /// The current reader's number; ``stop()`` and ``start(_:deliver:)`` move it on.
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private let mainWork: MainWorkScheduler
    private let workClass: BudgetedWorkClass
    private let owner: MainTaskOwner

    /// - Parameters:
    ///   - mainWork: The app's main-thread scheduler, where each page is applied.
    ///   - workClass: The class of a page's task: `automation` for mail an agent sent, `background` for
    ///     mail nobody sees yet.
    ///   - owner: The pages' owner in the board and the ledgers.
    public init(mainWork: MainWorkScheduler, workClass: BudgetedWorkClass, owner: String) {
        self.mainWork = mainWork
        self.workClass = workClass
        self.owner = mainWork.board.owner(owner)
    }

    /// Whether a reader runs.
    public var isRunning: Bool { task != nil }

    /// Stops the current reader, if any, and runs `reader`.
    ///
    /// - Parameters:
    ///   - reader: The reader to run.
    ///   - deliver: Gets each page of `reader` on the main actor, while `reader` is current.
    /// - Returns: The reader's task (tests await its end).
    @discardableResult
    public func start(_ reader: AcpmuxMailboxReader,
                      deliver: @escaping @MainActor @Sendable (AcpmuxMailboxPage) -> Void) -> Task<Void, Never> {
        stop()
        let current = generation, mainWork = mainWork, workClass = workClass, owner = owner
        let gated: @MainActor @Sendable (AcpmuxMailboxPage) -> Void = { [weak self] page in
            guard let self, self.generation == current else { return }
            deliver(page)
        }
        // task-owner: AcpmuxMailboxSubscription.task: the current reader, off main; ended by stop() or the next start.
        let task = Task { @concurrent in
            await reader.run { page in mainWork.postFromAnyThread(workClass, owner: owner) { gated(page) } }
        }
        self.task = task
        return task
    }

    /// Stops the current reader. A page it read before is dropped, also one
    /// already on its way to the main actor.
    public func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
