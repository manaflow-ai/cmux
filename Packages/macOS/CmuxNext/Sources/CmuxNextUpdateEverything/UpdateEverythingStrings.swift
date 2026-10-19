public import Foundation

/// Update Everything's words. Keys live in this module's Resources/Localizable.xcstrings. The App
/// reads its words through the receiver types below.
nonisolated enum UpdateEverythingStrings {
    static var title: String { text("updateEverything.title", "Update Everything?") }
    static var button: String { text("updateEverything.button", "Update Everything") }
    static var continueThreads: String { text("updateEverything.continueThreads", "Continue threads after restarts") }
    static var upToDate: String { text("updateEverything.machineUpToDate", "up to date") }
    static var relaunches: String { text("updateEverything.relaunches", "cmux restarts last to finish its own update.") }

    /// `devbox: cmux abc123 → def456`.
    static func machineLine(_ machine: String, _ changes: String) -> String {
        String(format: text("updateEverything.machineLine", "%1$@: %2$@"), machine, changes)
    }

    static func threadsRestart(_ count: Int) -> String {
        String(localized: "updateEverything.threadsRestart", defaultValue: "\(count) running threads restart on the new agent versions.", bundle: .module)
    }

    /// The toast when nothing anywhere needs an update.
    static var everythingUpToDate: String { text("updateEverything.everythingUpToDate", "Everything is up to date.") }
    /// The toast while a run goes.
    static var updating: String { text("updateEverything.updating", "Updating everything…") }
    /// The toast when a run ends with every machine updated.
    static var done: String { text("updateEverything.done", "Everything is updated.") }
    /// The refusal while a run goes.
    static var alreadyRunning: String { text("updateEverything.alreadyRunning", "Update Everything is already running.") }
    /// The refusal when no window is open to ask in.
    static var noWindow: String { text("updateEverything.noWindow", "Open a cmux window to update everything.") }
    /// A failure whose cause gave no words.
    static var updateFailed: String { text("updateEverything.updateFailed", "the update did not finish") }

    /// The toast line of one machine that failed.
    static func failed(_ machine: String, _ reason: String) -> String {
        String(format: text("updateEverything.failed", "Couldn't update %1$@: %2$@"), machine, reason)
    }

    /// The toast line of a machine whose threads could not restart on the new agent CLIs.
    static func threadsLeft(_ machine: String, _ reason: String) -> String {
        String(format: text("updateEverything.threadsLeft", "Threads on %1$@ still run the old agent: %2$@"), machine, reason)
    }

    /// The name of this Mac in the confirmation.
    static var thisMac: String { text("updateEverything.thisMac", "This Mac") }
    /// The refusal for a machine that disconnected during the run.
    static var disconnected: String { text("updateEverything.disconnected", "the machine is not connected") }
    /// A machine's cmux daemon in the confirmation.
    static var daemonName: String { text("updateEverything.daemonName", "cmux daemon") }

    private static func text(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, bundle: .module)
    }
}

extension UpdateEverythingRunner {
    /// The toast when nothing anywhere needs an update.
    public nonisolated static var everythingUpToDate: String { UpdateEverythingStrings.everythingUpToDate }
    /// The toast while a run goes.
    public nonisolated static var updating: String { UpdateEverythingStrings.updating }
    /// The toast when a run ends with every machine updated.
    public nonisolated static var done: String { UpdateEverythingStrings.done }
    /// The refusal while a run goes.
    public nonisolated static var alreadyRunning: String { UpdateEverythingStrings.alreadyRunning }
    /// The refusal when no window is open to ask in.
    public nonisolated static var noWindow: String { UpdateEverythingStrings.noWindow }
}

nonisolated extension UpdateEverythingMachine {
    /// The name of this Mac in the confirmation.
    public static var thisMac: String { UpdateEverythingStrings.thisMac }
    /// The refusal for a machine that disconnected during the run.
    public static var disconnected: String { UpdateEverythingStrings.disconnected }
    /// A machine's cmux daemon in the confirmation.
    public static var daemonName: String { UpdateEverythingStrings.daemonName }
    /// A failure whose cause gave no words.
    public static var updateFailed: String { UpdateEverythingStrings.updateFailed }

    /// `reason`, or ``updateFailed`` when it is missing or empty: a failure always says something.
    public static func failureText(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return updateFailed }
        return reason
    }
}

nonisolated extension UpdateEverythingOutcome {
    /// The toast line of one machine (or agent CLI) that failed.
    public static func failureLine(_ name: String, _ reason: String) -> String {
        UpdateEverythingStrings.failed(name, reason)
    }

    /// The run's result toast: a line per machine that failed or left threads on the old agent,
    /// or nil when everything updated.
    public static func summary(_ outcomes: [UpdateEverythingOutcome]) -> String? {
        let lines = outcomes.flatMap { outcome in
            [outcome.failure.map { failureLine(outcome.name, $0) },
             outcome.threadsLeft.map { UpdateEverythingStrings.threadsLeft(outcome.name, $0) }].compactMap { $0 }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
