import CmuxNextDaemon
import CmuxNextWakeups
import os

// The repair's daemon round trips (recipe R-hop, plans/cmux-next/chrome-parity/p06-scheduler.md): the daemon's
// answers are awaited off the main thread, and each step on the claim (`states`) is one task on the app's
// scheduler, in the class of the change that started it (`userBlocking` for a person's, `visible` for the
// program's, `automation` for an agent's or the CLI's). Chromium posts the reply of off-thread work back to the UI
// thread as a task of its own (`base::PostTaskAndReplyWithResult`, base/task/task_runner.h).
extension EmptyWorkspaceRepair {
    /// What the main-thread step of a decision found: refill a lost terminal, close a closed tab's workspace, or
    /// nothing (another path took the claim meanwhile).
    private nonisolated enum DecisionStep: Sendable {
        case refill
        case close
        case dropped
    }

    /// The class of the steps that follow the running turn: the class of the task running now (a person's change
    /// flushes in the input-response pass or as userBlocking), else the turn's cause (an action's run).
    var followingClass: BudgetedWorkClass {
        switch work.budget.board.running?.workClass {
        case .input?, .frame?, .userBlocking?: .userBlocking
        case .visible?: .visible
        case .automation?: .automation
        case .background?, .idle?: .background
        case nil: work.causes.currentCause.budgetedClass
        }
    }

    /// The decision for `key`, emptied and claimed (`.closing`) in this turn: asks the daemon why it lost its last
    /// pane, then refills or closes it.
    func decide(_ key: WorkspaceKey) {
        let close = close, cause = cause, create = create, work = work, logger = logger
        let workClass = followingClass
        // task-owner: one decision per emptied workspace; the claim (`states`) is its state
        Task { @concurrent [self] in
            let answer = await cause(key)
            let step = await work.apply(workClass, owner: "EmptyWorkspaceRepair.decide") { self.decided(key, answer) }
            switch step {
            case .dropped:
                return
            case .refill:
                do {
                    _ = try await create(key)
                } catch {
                    let reason = String(describing: error)
                    logger.error("refilling a workspace with a lost terminal failed: \(reason, privacy: .public)")
                    work.postFromAnyThread(workClass, owner: "EmptyWorkspaceRepair.failed") {
                        self.release(key, from: .awaitingPane, failure: reason)
                    }
                }
            case .close:
                do {
                    try await close(key)
                } catch {
                    logger.error("closing emptied workspace failed: \(String(describing: error), privacy: .public)")
                    // Still open and empty: the next change repairs it instead.
                    work.postFromAnyThread(workClass, owner: "EmptyWorkspaceRepair.failed") {
                        self.release(key, from: .closing, failure: nil)
                    }
                }
            }
        }
    }

    /// The decision's step on main. A lost terminal (its host died: crash, kill, reboot) is not a closed tab: the
    /// workspace stays and gets a new terminal, while the claim still holds.
    private func decided(_ key: WorkspaceKey, _ cause: EmptiedWorkspaceCause) -> DecisionStep {
        guard cause == .terminalLost else {
            record(key, .tabClosed)
            logger.info("workspace \(key.rawValue, privacy: .public) lost its last tab; closing it")
            return .close
        }
        guard states[key] == .closing else { return .dropped }
        states[key] = .awaitingPane
        record(key, .terminalLost)
        logger.info("workspace \(key.rawValue, privacy: .public) lost its last terminal; keeping it with a new terminal")
        return .refill
    }

    /// Creates `key`'s first tab once: the claim (`awaitingPane`) holds until the store shows its pane, and a
    /// failure releases it with its reason. The create runs off main; `created` runs on main with the new surface.
    func createTab(_ key: WorkspaceKey, create: @escaping @MainActor (WorkspaceKey) async throws -> SurfaceID?,
                   created: @escaping @MainActor (SurfaceID) -> Void) {
        guard states[key] == nil, canCreate() else { return }
        states[key] = .awaitingPane
        logger.info("workspace \(key.rawValue, privacy: .public) requested a new tab")
        let work = work, logger = logger
        let workClass = followingClass
        // task-owner: one first tab per claim (`states`); a failure releases the claim
        Task { @concurrent [self] in
            do {
                guard let surface = try await create(key) else { return }
                work.postFromAnyThread(workClass, owner: "EmptyWorkspaceRepair.created") {
                    self.answeredCreates += 1
                    created(surface)
                }
            } catch {
                let reason = String(describing: error)
                logger.error("creating a terminal for an empty workspace failed: \(reason, privacy: .public)")
                work.postFromAnyThread(workClass, owner: "EmptyWorkspaceRepair.failed") {
                    self.release(key, from: .awaitingPane, failure: reason)
                }
            }
        }
    }

    /// A step on `key` failed: its claim goes when it is still `claim`, with the failure's reason when it has one
    /// (shown with a retry, never refilled by itself on this connection).
    func release(_ key: WorkspaceKey, from claim: FirstTerminal, failure reason: String?) {
        guard states[key] == claim else { return }
        states[key] = nil
        if let reason { recordFailure(key, reason: reason) }
    }
}
