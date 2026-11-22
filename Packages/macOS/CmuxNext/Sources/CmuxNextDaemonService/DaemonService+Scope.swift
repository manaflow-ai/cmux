public import CmuxNextDaemon

/// A command ticket in the running action's scope.
public struct CommandTicket {
    let scope: DaemonCommandScope
    let ticket: DaemonCommandScope.Ticket
}

/// Every command funnel (`run`, `runReportingTimeout`, `send`, `failure`,
/// `perform`, `commit`, `intend`, `request`) reports to the action scope it runs in
/// (`DaemonCommandScope.current`, bound by the control socket's
/// `action.run`), so an action run from the CLI answers after every command
/// its handlers sent, whether they awaited it, tracked it, or started it in
/// a plain task (plans/cmux-next/state-ownership.md 4.2).
extension DaemonService {
    /// Opens a ticket on entry (synchronously, on the main actor), so the
    /// scope is not idle between a task's commands.
    public func openTicket(_ label: String? = nil) -> CommandTicket? {
        guard let scope = DaemonCommandScope.current, let ticket = scope.begin(label: label) else { return nil }
        return CommandTicket(scope: scope, ticket: ticket)
    }

    /// Records the command's outcome and the event sequence that covers its
    /// echo, then closes the ticket. Runs on the main actor, so a task's next
    /// command opens its ticket before an idle check on the main actor.
    /// `replying` is the connection that answered the command (the current
    /// one when nil): after a reconnect, the new connection's sequence does
    /// not cover the old one's echo.
    public func closeTicket(_ ticket: CommandTicket?, label: String, error: (any Error)?, replying: DaemonConnection? = nil) async {
        guard let ticket else { return }
        ticket.scope.note("reply \(label)")
        if error == nil, let source = replying ?? connection, let sequence = await source.eventSequence() {
            ticket.scope.noteBarrier(sequence, machine: machineID)
        }
        ticket.scope.end(ticket.ticket, failure: error.map { Self.scopeFailure(label, $0) }, label: label)
    }

    static func scopeFailure(_ label: String, _ error: any Error) -> DaemonCommandScope.Failure {
        let daemonError = error as? DaemonError
        let terminal = daemonError?.isTerminalStartTimeout == true
        var timedOut = terminal
        // A close past its bound with no answer (`CloseUnanswered`) may still apply, as a timeout may.
        if case .timedOut = daemonError { timedOut = true } else if error is CloseUnanswered { timedOut = true }
        return DaemonCommandScope.Failure(label: label, message: "\(label): \(error)", mayHaveApplied: timedOut, terminalMayAppear: terminal)
    }
}
