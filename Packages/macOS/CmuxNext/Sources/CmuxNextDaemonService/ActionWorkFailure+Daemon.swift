public import CmuxNextActions
public import CmuxNextDaemon

extension ActionWorkFailure {
    /// The failure of the daemon command `label`. A terminal start that
    /// missed its deadline says the terminal may still appear, so the
    /// control socket answers a typed timeout instead of a plain error.
    ///
    /// A typed ``ActionFailure`` from the handler's own work stays a refusal (its code and reason
    /// on the control socket, as when the handler throws it at once), not a daemon failure.
    public init(_ label: String, _ error: any Error) {
        if let failure = error as? ActionFailure {
            self.init(failure)
            return
        }
        // A pane verb on a pane still opening was refused before it was sent (rule a): a typed refusal, so the control
        // socket answers `unavailable` and the HUD shows the text alone, once, in the person's language.
        if let notReady = error as? PaneNotReady {
            self.init(refusal: .unavailable, reason: RefusalStrings.paneStillOpening)
            shown = notReady.shown
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
    public init(_ failure: ActionFailure) {
        self.init(refusal: failure.isNotFound ? .notFound : .unavailable, reason: failure.message)
    }
}

extension DaemonError {
    nonisolated var isTerminalStartTimeout: Bool {
        if case .terminalStartTimedOut = self { return true }
        return false
    }
}

extension ActionWorkFailure {
    /// The failure of a person's optimistic create (Cmd-D, Ctrl-`, New Row, New Column) as the refusal HUD shows it:
    /// ``PendingPaneNotCreated`` and ``PaneNotReady`` read in the app's language (their English text stays for the log);
    /// other errors keep the daemon's own text, as before.
    @MainActor public static func create(_ label: String, _ error: any Error) -> ActionWorkFailure {
        if error is PendingPaneNotCreated { return ActionWorkFailure("\(label): \(RefusalStrings.pendingPaneNotCreated)") }
        return ActionWorkFailure(label, error)
    }
}
