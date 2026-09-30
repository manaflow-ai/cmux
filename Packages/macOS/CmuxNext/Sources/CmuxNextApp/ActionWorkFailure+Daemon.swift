import CmuxNextActions
import CmuxNextDaemon

extension ActionWorkFailure {
    /// The failure of the daemon command `label`. A terminal start that
    /// missed its deadline says the terminal may still appear, so the
    /// control socket answers a typed timeout instead of a plain error.
    init(_ label: String, _ error: any Error) {
        self.init("\(label): \(error)", terminalMayAppear: (error as? DaemonError)?.isTerminalStartTimeout == true)
    }
}

extension DaemonError {
    var isTerminalStartTimeout: Bool {
        if case .terminalStartTimedOut = self { return true }
        return false
    }
}
