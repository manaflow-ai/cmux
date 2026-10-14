public import Foundation

/// Update Everything's words. Keys live in this module's Resources/Localizable.xcstrings.
public nonisolated enum UpdateEverythingStrings {
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
    public static var everythingUpToDate: String { text("updateEverything.everythingUpToDate", "Everything is up to date.") }
    /// The toast while a run goes.
    public static var updating: String { text("updateEverything.updating", "Updating everything…") }
    /// The toast when a run ends with every machine updated.
    public static var done: String { text("updateEverything.done", "Everything is updated.") }
    /// The refusal while a run goes.
    public static var alreadyRunning: String { text("updateEverything.alreadyRunning", "Update Everything is already running.") }

    /// The toast line of one machine that failed.
    public static func failed(_ machine: String, _ reason: String) -> String {
        String(format: text("updateEverything.failed", "Couldn't update %1$@: %2$@"), machine, reason)
    }

    /// The name of this Mac in the confirmation.
    public static var thisMac: String { text("updateEverything.thisMac", "This Mac") }
    /// The refusal for a machine that disconnected during the run.
    public static var disconnected: String { text("updateEverything.disconnected", "the machine is not connected") }
    /// A machine's cmux daemon in the confirmation.
    public static var daemonName: String { text("updateEverything.daemonName", "cmux daemon") }

    private static func text(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, bundle: .module)
    }
}
