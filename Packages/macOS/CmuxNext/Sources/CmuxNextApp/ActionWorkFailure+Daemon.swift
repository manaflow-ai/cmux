import CmuxNextActions
import CmuxNextDaemon

extension ActionWorkFailure {
    /// The failure of the daemon command `label`. A terminal start that
    /// missed its deadline says the terminal may still appear, so the
    /// control socket answers a typed timeout instead of a plain error.
    ///
    /// A typed ``ActionFailure`` from the handler's own work stays a refusal (its code and reason
    /// on the control socket, as when the handler throws it at once), not a daemon failure.
    init(_ label: String, _ error: any Error) {
        if let failure = error as? ActionFailure {
            self.init(failure)
            return
        }
        let daemonError = error as? DaemonError
        var timedOut = false
        if case .timedOut = daemonError { timedOut = true }
        self.init("\(label): \(error)", mayHaveApplied: timedOut, terminalMayAppear: daemonError?.isTerminalStartTimeout == true)
    }
}

extension ActionWorkFailure {
    /// A handler's typed refusal, reported from its background work.
    init(_ failure: ActionFailure) {
        self.init(refusal: failure.isNotFound ? .notFound : .unavailable, reason: failure.message)
    }
}

extension DaemonError {
    var isTerminalStartTimeout: Bool {
        if case .terminalStartTimedOut = self { return true }
        return false
    }
}
