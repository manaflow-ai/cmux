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
    static func execUnavailable(_ machineID: String) -> String {
        String(format: String(localized: "cloud.cli.execUnavailable",
                              defaultValue: "This Cloud machine can't run a command for the CLI and return its output. Open a terminal on it with `cmux cloud new-terminal-on-machine --target machine:%1$@`, or connect with `cmux cloud ssh --target machine:%1$@`.",
                              table: "Cloud", bundle: .module), machineID)
    }

    /// A run whose `--target machine:<id>` names no machine this app knows.
    static func unknownMachine(_ machineID: String) -> String {
        String(format: String(localized: "cloud.cli.unknownMachine",
                              defaultValue: "No Cloud machine has the id %@. `cmux cloud list-machines` lists ids.",
                              table: "Cloud", bundle: .module), machineID)
    }

    /// `cloud set-idle-pause` with a `minutes` value the server does not take.
    static func idlePauseMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.cli.idlePauseMustBeOneOf", defaultValue: "Minutes must be one of: %@.", table: "Cloud", bundle: .module), list)
    }
}
