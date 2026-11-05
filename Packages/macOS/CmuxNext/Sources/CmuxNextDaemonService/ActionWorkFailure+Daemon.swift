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
        // socket answers `unavailable` and the HUD shows the text alone, once. `DaemonService.workFailure` puts it in the
        // person's language; here the English text.
        if let notReady = error as? PaneNotReady {
            self.init(refusal: .unavailable, reason: notReady.reason)
            shown = notReady.shown
            return
        }
        // A close past its bound with no answer: its result is unknown (`CloseUnanswered`). A caller reads that it may
        // still apply (a timeout, not a refusal); the person reads why.
        if let unanswered = error as? CloseUnanswered {
            self.init("\(label): \(unanswered)", mayHaveApplied: true)
            shownReason = unanswered.description
            cause = .text // unlike a missed deadline, a close that may still happen is said (#30915)
            return
        }
        let daemonError = error as? DaemonError
        self.init("\(label): \(error)", mayHaveApplied: daemonError?.isMissedDeadline == true,
                  terminalMayAppear: daemonError?.isTerminalStartTimeout == true)
        // What a person reads (`notice(title:)`): never the daemon's text, the command label or an op name. A missed
        // deadline shows nothing (the store's echo shows what the daemon holds); a refusal or a lost connection, only "did not apply".
        if cause == .text { cause = daemonError?.isLostConnection == true ? .connection : .daemon }
        // The person reads why in their language; a caller keeps the daemon's error (restore fuzz h3).
        if daemonError?.isDiskFull == true { shownReason = RefusalStrings.diskFull }
        switch daemonError {
        case .missingCapabilities?, .sessionRestoreTimedOut?: shownReason = RefusalStrings.describe(error)
        case .endpointBlocked(let reason)?: shownReason = reason
        default: break
        }
        // A missed deadline's reason in words, for a surface that shows one; a toast shows nothing (`notice(title:)`).
        if daemonError?.isMissedDeadline == true { shownReason = RefusalStrings.daemonTimedOut }
    }
}

extension ActionWorkFailure {
    /// A handler's typed refusal, reported from its background work.
    public init(_ failure: ActionFailure) {
        self.init(refusal: failure.isNotFound ? .notFound : .unavailable, reason: failure.message)
    }
}

extension DaemonError {
    var isTerminalStartTimeout: Bool {
        if case .terminalStartTimedOut = self { return true }
        return false
    }
}

/// A workspace close whose machine did not answer within its bound (`DaemonService.closeReplyBound`), and whose
/// workspace its store still lists: the result is unknown, since a paused daemon may still close it later.
public struct CloseUnanswered: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { RefusalStrings.closeUnanswered }
}
