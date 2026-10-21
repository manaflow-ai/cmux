import Foundation

/// What a CLI or agent run of a Cloud action hears back. Keys live in
/// Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
    /// `cloud new-machine` from a CLI or agent: the person said no in the confirmation, or
    /// dismissed the creation, so no machine was made.
    static var createDeclined: String {
        String(localized: "cloud.cli.createDeclined", defaultValue: "No Cloud machine was created: the person declined or dismissed it in cmux.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud exec` from a CLI or agent on a machine whose provider runs no commands through the
    /// API: typing it into a tab would give the caller nothing to read.
    static var execUnavailable: String {
        String(localized: "cloud.cli.execUnavailable",
               defaultValue: "This Cloud machine can't run a command for the CLI and return its output. Open a terminal on it with cmux cloud open-machine instead.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud list-machines` from a CLI or agent while signed in, when the machine list has not
    /// loaded: an empty answer would read as "no machines" and start a second one.
    static var machineListUnavailable: String {
        String(localized: "cloud.cli.machineListUnavailable",
               defaultValue: "The Cloud machine list hasn't loaded, so cmux can't say which machines exist. Try again, or run cmux cloud diagnostics.",
               table: "Cloud", bundle: .module)
    }
}
