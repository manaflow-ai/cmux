import CmuxNextActions
import CmuxNextDaemon
import CmuxNextWakeups
import os

/// One command a sender started without awaiting it (`DaemonService.send`, a cancelled creation's close), read in
/// the sender's turn: its connection, its ticket in the action's scope and the class of the sender's cause. It runs
/// off the main thread (recipe R-hop, plans/cmux-next/chrome-parity/p06-scheduler.md): the command on the
/// connection's actor, the ticket's close in the scope (thread-safe), and only its end on main, as one task in
/// ``workClass``. Chromium posts the reply of work on another sequence back to the UI thread as a task of its own
/// (`base::PostTaskAndReplyWithResult`, base/task/task_runner.h).
nonisolated struct DaemonCommandSend: Sendable {
    /// How the command ended.
    nonisolated enum Ended {
        case succeeded
        /// The daemon refused or failed it, or no connection was there (``DaemonError/notConnected``).
        case failed(any Error)

        /// The command's reply missed its deadline: the daemon may still apply it.
        var timedOut: Bool {
            guard case .failed(let error) = self, case .timedOut? = error as? DaemonError else { return false }
            return true
        }
    }

    let label: String
    /// The connection the command runs on; nil when there was none in the sender's turn.
    let connection: DaemonConnection?
    let scope: DaemonCommandScope?
    let ticket: DaemonCommandScope.Ticket?
    /// The machine whose event sequence covers the command's echo.
    let machine: String
    /// The class of the command's end on main: `userBlocking` for a person's run (the rest of their action),
    /// `automation` for an agent's or the CLI's, `visible` for a change the program or a frontend made.
    let workClass: BudgetedWorkClass
    let logger: Logger

    /// Runs `body` on the connection, off main. A success closes the ticket here, with the event sequence that covers
    /// the command's echo; a failure leaves it open for ``close(failure:)``, so the sender's reaction on main (a
    /// follow-up command) opens its ticket before the action's scope goes idle, as when the ticket closed on main.
    @concurrent func run(_ body: DaemonCommandBody) async -> Ended {
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            return .failed(DaemonError.notConnected)
        }
        do {
            try await body(connection)
            scope?.note("reply \(label)")
            if scope != nil, let sequence = await connection.eventSequence() { scope?.noteBarrier(sequence, machine: machine) }
            scope?.end(ticket, label: label)
            return .succeeded
        } catch {
            if case .timedOut(let what)? = error as? DaemonError {
                logger.info("\(label, privacy: .public) outcome unknown: \(what, privacy: .public)")
            } else {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            return .failed(error)
        }
    }

    /// Closes the ticket of a command that failed with `error` (``run(_:)``'s `.failed`).
    func close(failure error: any Error) {
        scope?.note("reply \(label)")
        scope?.end(ticket, failure: DaemonService.scopeFailure(label, error), label: label)
    }
}

extension DaemonService {
    /// The class of the end on main of work the running turn starts: its action run's cause
    /// (``ActionRunScope``), else the cause of the change applying now.
    var causeClass: BudgetedWorkClass {
        (ActionRunScope.current?.origin.observationCause ?? mainWork.causes.currentCause).budgetedClass
    }

    /// `label`'s command as this turn starts it: the connection, a ticket in the action's scope, the cause's class.
    func commandSend(_ label: String) -> DaemonCommandSend {
        let ticket = openTicket(label)
        return DaemonCommandSend(label: label, connection: connection, scope: ticket?.scope, ticket: ticket?.ticket,
                                 machine: machineID, workClass: causeClass, logger: logger)
    }

    /// Starts `body` off main and returns the task, whose value is the failure; `onFailure` gets it on main, in the
    /// same task as the failure is made (``DaemonCommandSend/workClass``).
    func startSend(_ label: String, onFailure: (@MainActor (ActionWorkFailure) -> Void)?,
                   _ body: @escaping DaemonCommandBody) -> ActionWork {
        let command = commandSend(label)
        let mainWork = mainWork
        // task-owner: the command's one run; `workTracker` and the action's scope wait for it
        return Task { @concurrent [self] in
            guard case .failed(let error) = await command.run(body) else { return nil }
            return await mainWork.apply(command.workClass, owner: "DaemonService.send") {
                command.close(failure: error)
                // A pane still opening (``PaneNotReady``) was shown where the connection refused it, and the error says
                // so (``PaneNotReady/shown``): no reporter shows it again.
                let failure = command.connection == nil
                    ? ActionWorkFailure("\(label): \(self.notConnectedReason ?? DaemonError.notConnected.description)")
                    : self.workFailure(label, error)
                onFailure?(failure)
                return failure
            }
        }
    }
}
